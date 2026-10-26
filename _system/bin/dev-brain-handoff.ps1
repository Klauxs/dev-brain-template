#Requires -Version 5.1
<#
Queue a dev-brain handoff for the local curator (Windows / PowerShell port of
_system/bin/dev-brain-handoff). After queuing, it starts the "dev-brain-curator"
scheduled task when one is installed (dev-brain-curator.ps1 install).

Usage:
  @'
  dev-brain handoff
  project: ...
  '@ | & dev-brain-handoff.ps1                    Queue a handoff from the pipeline.
  dev-brain-handoff.ps1 -InputFile handoff.txt    Queue a handoff from a file.
  dev-brain-handoff.ps1 -Status                   Print queue counts and the curator lock.
  dev-brain-handoff.ps1 -RecoverStale [-StaleMinutes N]
                                                  Requeue running jobs left by a dead curator run.
  Add -QueueDir DIR to any of them to use another queue.
#>
[CmdletBinding(DefaultParameterSetName = 'Enqueue')]
param(
  [Parameter(ValueFromPipeline = $true, ParameterSetName = 'Enqueue')]
  [string[]]$InputObject,
  [Parameter(ParameterSetName = 'Enqueue')]
  [string]$InputFile,
  [Parameter(ParameterSetName = 'Status')]
  [switch]$Status,
  [Parameter(ParameterSetName = 'Recover')]
  [switch]$RecoverStale,
  [Parameter(ParameterSetName = 'Recover')]
  [int]$StaleMinutes = -1,
  [string]$QueueDir
)

begin {
  $ErrorActionPreference = 'Stop'
  $Utf8 = New-Object System.Text.UTF8Encoding $false
  $collected = New-Object System.Collections.Generic.List[string]

  if (-not $QueueDir) {
    $QueueDir = if ($env:DEV_BRAIN_HANDOFF_QUEUE) { $env:DEV_BRAIN_HANDOFF_QUEUE } else { Join-Path $HOME '.codex/dev-brain-curator-queue' }
  }
  if ($StaleMinutes -lt 0) {
    $StaleMinutes = if ($env:DEV_BRAIN_HANDOFF_STALE_MINUTES) { [int]$env:DEV_BRAIN_HANDOFF_STALE_MINUTES } else { 30 }
  }
  $Lock = Join-Path $QueueDir '.worker.lock'
  $OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows

  function Initialize-QueueDirs {
    foreach ($d in 'pending', 'running', 'done', 'failed', 'logs') {
      $null = New-Item -ItemType Directory -Force -Path (Join-Path $QueueDir $d)
    }
  }

  function Get-LockPid {
    $f = Join-Path $Lock 'pid'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $first = [IO.File]::ReadAllLines($f) | Select-Object -First 1
    if ($first -match '^\d+$') { return [int]$first }
    return $null
  }

  function Test-PidAlive([object]$ProcessId) {
    if ($null -eq $ProcessId) { return $false }
    return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
  }

  function Get-TxtFiles([string]$Bucket) {
    $dir = Join-Path $QueueDir $Bucket
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.txt' -File)
  }

  function Invoke-RequeueRunning {
    foreach ($f in Get-TxtFiles 'running') {
      $dest = Join-Path (Join-Path $QueueDir 'pending') $f.Name
      if (Test-Path -LiteralPath $dest) {
        $dest = Join-Path (Join-Path $QueueDir 'pending') ($f.BaseName + '-recovered.txt')
      }
      Move-Item -LiteralPath $f.FullName -Destination $dest
    }
  }

  function Start-CuratorTask {
    if (-not $OnWindows -or $env:DEV_BRAIN_HANDOFF_NO_TRIGGER -eq '1') { return }
    try {
      $task = Get-ScheduledTask -TaskName 'dev-brain-curator' -ErrorAction SilentlyContinue
      if ($task) { Start-ScheduledTask -TaskName 'dev-brain-curator' }
    } catch {
      Write-Warning "queued, but could not start the curator task: $_"
    }
  }
}

process {
  if ($PSCmdlet.ParameterSetName -eq 'Enqueue' -and $InputObject) {
    foreach ($line in $InputObject) { $collected.Add($line) }
  }
}

end {
  switch ($PSCmdlet.ParameterSetName) {
    'Status' {
      Initialize-QueueDirs
      "queue: $QueueDir"
      foreach ($b in 'pending', 'running', 'done', 'failed') { "${b}: $((Get-TxtFiles $b).Count)" }
      if (Test-Path -LiteralPath $Lock) {
        $lockPid = Get-LockPid
        $pidText = if ($null -ne $lockPid) { $lockPid } else { 'unknown' }
        if (Test-PidAlive $lockPid) { "lock: present pid=$pidText alive=1" } else { "lock: present pid=$pidText alive=0" }
      } else {
        'lock: absent'
      }
      exit 0
    }
    'Recover' {
      Initialize-QueueDirs
      if (-not (Test-Path -LiteralPath $Lock)) {
        if ((Get-TxtFiles 'running').Count -gt 0) {
          Invoke-RequeueRunning
          'recovered orphaned running jobs'
        } else {
          'no worker lock'
        }
        exit 0
      }
      $lockPid = Get-LockPid
      if (Test-PidAlive $lockPid) {
        "curator still running: pid $lockPid"
        exit 1
      }
      $age = [int]((Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $Lock).LastWriteTimeUtc).TotalSeconds
      $threshold = $StaleMinutes * 60
      if ($age -lt $threshold) {
        "worker lock is not stale yet: age=${age}s threshold=${threshold}s"
        exit 1
      }
      Invoke-RequeueRunning
      Remove-Item -LiteralPath $Lock -Recurse -Force
      "recovered stale worker lock: age=${age}s"
      exit 0
    }
    default {
      Initialize-QueueDirs
      if ($InputFile) {
        $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $InputFile).ProviderPath, $Utf8)
      } elseif ($collected.Count -gt 0) {
        $text = ($collected -join "`n") + "`n"
      } elseif ([Console]::IsInputRedirected) {
        [Console]::InputEncoding = $Utf8
        $text = [Console]::In.ReadToEnd()
      } else {
        Write-Error 'no handoff given: pipe it in or pass -InputFile' -ErrorAction Continue
        exit 64
      }
      $text = $text -replace "`r`n", "`n"

      $jobId = '{0}-{1}-{2}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'), $PID, (Get-Random -Maximum 32768)
      $firstLine = ($text -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -First 1)
      if ($null -ne $firstLine) { $firstLine = $firstLine.Trim() }
      if ($firstLine -ne 'dev-brain handoff') {
        $bad = Join-Path (Join-Path $QueueDir 'failed') "$jobId.txt"
        [IO.File]::WriteAllText($bad, $text, $Utf8)
        [Console]::Error.WriteLine("not a dev-brain handoff: $bad")
        exit 2
      }

      # Write next to the queue first, then rename into pending/, so the curator
      # never picks up a half-written file.
      $incoming = Join-Path $QueueDir ".incoming-$jobId.txt"
      [IO.File]::WriteAllText($incoming, $text, $Utf8)
      Move-Item -LiteralPath $incoming -Destination (Join-Path (Join-Path $QueueDir 'pending') "$jobId.txt")
      "queued: $jobId"
      Start-CuratorTask
      exit 0
    }
  }
}
