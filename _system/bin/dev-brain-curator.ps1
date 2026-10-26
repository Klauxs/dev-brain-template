#Requires -Version 5.1
<#
dev-brain curator runner (Windows / PowerShell port of _system/bin/dev-brain-curator):
drains the local handoff queue with a fresh headless Codex session per batch,
commits exactly the paths Codex reports, and syncs the vault with Git.
See _system/curator-session.md.

Usage:
  dev-brain-curator.ps1 run        Process pending handoffs until the queue is empty, then sync Git.
  dev-brain-curator.ps1 sync       Only sync the vault with its upstream (pull --rebase, push).
  dev-brain-curator.ps1 status     Show queue counts, lock, scheduled task state and the last run.
  dev-brain-curator.ps1 install    Register the "dev-brain-curator" scheduled task (hourly + at logon;
                                   dev-brain-handoff.ps1 starts it after each enqueue).
  dev-brain-curator.ps1 uninstall  Remove the scheduled task.

Configuration: ~/.config/dev-brain/curator.env (KEY=value lines), e.g.
  DEV_BRAIN_CURATOR_MODEL=gpt-6.1-sol
  DEV_BRAIN_CURATOR_EFFORT=medium
  CODEX_BIN=C:\Users\me\AppData\Roaming\npm\codex.cmd
#>
param([Parameter(Position = 0)][string]$Command = 'help')

$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $Utf8
$OutputEncoding = $Utf8
$OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows

$ScriptPath = $PSCommandPath
$Vault = if ($env:DEV_BRAIN_VAULT) { $env:DEV_BRAIN_VAULT } else { Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptPath)) }
$Vault = [IO.Path]::GetFullPath($Vault)
$ConfigFile = if ($env:DEV_BRAIN_CURATOR_CONFIG) { $env:DEV_BRAIN_CURATOR_CONFIG } else { Join-Path $HOME '.config/dev-brain/curator.env' }
if (Test-Path -LiteralPath $ConfigFile) {
  foreach ($line in [IO.File]::ReadAllLines($ConfigFile, $Utf8)) {
    if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
      $value = $Matches[2].Trim()
      if ($value -match '^"(.*)"$' -or $value -match "^'(.*)'$") { $value = $Matches[1] }
      [Environment]::SetEnvironmentVariable($Matches[1], $value, 'Process')
    }
  }
}

function Get-Setting([string]$Name, [string]$Default) {
  $v = [Environment]::GetEnvironmentVariable($Name, 'Process')
  if ([string]::IsNullOrEmpty($v)) { return $Default }
  return $v
}

$QueueDir = Get-Setting 'DEV_BRAIN_HANDOFF_QUEUE' (Join-Path $HOME '.codex/dev-brain-curator-queue')
$CodexBin = Get-Setting 'CODEX_BIN' 'codex'
$Model = Get-Setting 'DEV_BRAIN_CURATOR_MODEL' 'gpt-6.1-sol'
$Effort = Get-Setting 'DEV_BRAIN_CURATOR_EFFORT' 'medium'
$BatchSize = [int](Get-Setting 'DEV_BRAIN_CURATOR_BATCH' '5')
$RunTimeout = [int](Get-Setting 'DEV_BRAIN_CURATOR_TIMEOUT' '1800')
$LockWait = [int](Get-Setting 'DEV_BRAIN_CURATOR_LOCK_WAIT' '900')
$MaxAttempts = [int](Get-Setting 'DEV_BRAIN_CURATOR_MAX_ATTEMPTS' '3')
$Interval = [int](Get-Setting 'DEV_BRAIN_CURATOR_INTERVAL' '3600')
$KeepRuns = [int](Get-Setting 'DEV_BRAIN_CURATOR_KEEP_RUNS' '60')
$AutosaveIdle = [int](Get-Setting 'DEV_BRAIN_CURATOR_AUTOSAVE_IDLE' '7200')
$TaskName = 'dev-brain-curator'
$Schema = Join-Path $Vault '_system/curator-output.schema.json'
$LockDir = Join-Path $QueueDir '.worker.lock'

$script:HaveLock = $false
$script:RunId = ''
$script:RunLog = $null
$script:SyncResult = 'not run'
$script:Commits = New-Object System.Collections.Generic.List[string]
$script:Autosaved = New-Object System.Collections.Generic.List[string]
$script:Counts = [ordered]@{ done = 0; skipped = 0; deferred = 0; failed = 0; duplicate = 0 }
$script:BatchSeq = 0

function Exit-Usage([int]$Code) {
  $help = @'
Usage:
  dev-brain-curator.ps1 run        Process pending handoffs until the queue is empty, then sync Git.
  dev-brain-curator.ps1 sync       Only sync the vault with its upstream (pull --rebase, push).
  dev-brain-curator.ps1 status     Show queue counts, lock, scheduled task state and the last run.
  dev-brain-curator.ps1 install    Register the "dev-brain-curator" scheduled task.
  dev-brain-curator.ps1 uninstall  Remove the scheduled task.

Configuration: ~/.config/dev-brain/curator.env (KEY=value lines), e.g.
  DEV_BRAIN_CURATOR_MODEL=gpt-6.1-sol
  DEV_BRAIN_CURATOR_EFFORT=medium
'@
  if ($Code -eq 0) { Write-Output $help } else { [Console]::Error.WriteLine($help) }
  exit $Code
}

function Stop-WithError([string]$Message) {
  [Console]::Error.WriteLine($Message)
  exit 64
}

function Q([string]$Name) { Join-Path $QueueDir $Name }

function Write-Text([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, $Utf8) }

function Write-Note([string]$Message) {
  if ($script:RunLog) {
    [IO.File]::AppendAllText($script:RunLog, ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) + "`n", $Utf8)
  }
}

function Initialize-Dirs {
  foreach ($d in 'pending', 'running', 'done', 'failed', 'logs', 'attempts') {
    $null = New-Item -ItemType Directory -Force -Path (Q $d)
  }
}

function Get-QueueFiles([string]$Bucket, [string]$Filter = '*.txt') {
  $dir = Q $Bucket
  if (-not (Test-Path -LiteralPath $dir)) { return @() }
  return @(Get-ChildItem -LiteralPath $dir -Filter $Filter -File | Sort-Object Name)
}

# Runs a native command without letting its stderr turn into terminating errors
# (Windows PowerShell 5.1 does that under ErrorActionPreference=Stop).
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prev
  }
  return [pscustomobject]@{ Code = $code; Out = $out }
}

function Invoke-Git([string[]]$Arguments, [switch]$Log) {
  $r = Invoke-Native 'git' (@('-c', 'core.quotepath=false', '-C', $Vault) + $Arguments)
  if ($Log -and $script:RunLog -and $r.Out.Count) {
    [IO.File]::AppendAllText($script:RunLog, (($r.Out -join "`n") + "`n"), $Utf8)
  }
  return $r
}

function Get-LockPid {
  $f = Join-Path $LockDir 'pid'
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  $first = [IO.File]::ReadAllLines($f) | Select-Object -First 1
  if ($first -match '^\d+$') { return [int]$first }
  return $null
}

function Test-PidAlive([object]$ProcessId) {
  if ($null -eq $ProcessId) { return $false }
  return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Test-LockStale {
  if (Test-PidAlive (Get-LockPid)) { return $false }
  $item = Get-Item -LiteralPath $LockDir -ErrorAction SilentlyContinue
  if (-not $item) { return $true }
  return ((Get-Date).ToUniversalTime() - $item.LastWriteTimeUtc).TotalSeconds -gt 30
}

function Invoke-RequeueRunning {
  foreach ($f in Get-QueueFiles 'running') {
    Move-Item -LiteralPath $f.FullName -Destination (Join-Path (Q 'pending') $f.Name) -Force
  }
  foreach ($f in Get-QueueFiles 'running' '*.sha256') { Remove-Item -LiteralPath $f.FullName -Force }
}

function Enter-Lock {
  $waited = 0
  while ($true) {
    try {
      $null = New-Item -ItemType Directory -Path $LockDir -ErrorAction Stop
      break
    } catch {
      if (Test-LockStale) {
        Remove-Item -LiteralPath $LockDir -Recurse -Force -ErrorAction SilentlyContinue
        continue
      }
      if ($waited -ge $LockWait) { return $false }
      Start-Sleep -Seconds 2
      $waited += 2
    }
  }
  Write-Text (Join-Path $LockDir 'pid') "$PID`n"
  Write-Text (Join-Path $LockDir 'meta') ("pid=$PID`nholder=dev-brain-curator`nstarted_at={0}`n" -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
  $script:HaveLock = $true
  return $true
}

function Exit-Lock {
  if ($script:HaveLock) {
    Remove-Item -LiteralPath $LockDir -Recurse -Force -ErrorAction SilentlyContinue
    $script:HaveLock = $false
  }
}

function Start-Run {
  Initialize-Dirs
  $script:RunId = '{0}-{1}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'), $PID
  $script:RunLog = Join-Path (Q 'logs') "run-$($script:RunId).log"
  if (-not (Enter-Lock)) {
    [IO.File]::AppendAllText((Join-Path (Q 'logs') 'runs.log'), ('{0} run={1} skipped: another curator run held the lock for {2}s' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $script:RunId, $LockWait) + "`n", $Utf8)
    exit 75
  }
}

function Get-AttemptsFile([string]$Id) { Join-Path (Q 'attempts') $Id }

function Complete-Job([string]$Id, [string]$Result, [string]$Reason) {
  $job = Join-Path (Q 'running') "$Id.txt"
  $sha = Join-Path (Q 'running') "$Id.sha256"
  $attemptsFile = Get-AttemptsFile $Id
  $lastCommit = if ($script:Commits.Count) { $script:Commits[$script:Commits.Count - 1] } else { '' }
  switch ($Result) {
    { $_ -in 'done', 'skipped' } {
      Move-Item -LiteralPath $job -Destination (Join-Path (Q 'done') "$Id.txt") -Force
      if (Test-Path -LiteralPath $sha) { Move-Item -LiteralPath $sha -Destination (Join-Path (Q 'done') "$Id.sha256") -Force }
      Write-Text (Join-Path (Q 'done') "$Id.result") "$Result`t$Reason`trun=$($script:RunId)`tcommit=$lastCommit`n"
      Remove-Item -LiteralPath $attemptsFile -Force -ErrorAction SilentlyContinue
    }
    'failed' {
      Move-Item -LiteralPath $job -Destination (Join-Path (Q 'failed') "$Id.txt") -Force
      Remove-Item -LiteralPath $sha -Force -ErrorAction SilentlyContinue
      Write-Text (Join-Path (Q 'failed') "$Id.result") "failed`t$Reason`trun=$($script:RunId)`n"
      Remove-Item -LiteralPath $attemptsFile -Force -ErrorAction SilentlyContinue
    }
    default {
      $attempts = 1
      if (Test-Path -LiteralPath $attemptsFile) { $attempts = [int]([IO.File]::ReadAllText($attemptsFile).Trim()) + 1 }
      Remove-Item -LiteralPath $sha -Force -ErrorAction SilentlyContinue
      if ($attempts -ge $MaxAttempts) {
        Move-Item -LiteralPath $job -Destination (Join-Path (Q 'failed') "$Id.txt") -Force
        Write-Text (Join-Path (Q 'failed') "$Id.result") "failed`tgave up after $attempts attempts: $Reason`trun=$($script:RunId)`n"
        Remove-Item -LiteralPath $attemptsFile -Force -ErrorAction SilentlyContinue
        $Result = 'failed'
      } else {
        Write-Text $attemptsFile "$attempts`n"
        Move-Item -LiteralPath $job -Destination (Join-Path (Q 'pending') "$Id.txt") -Force
        $Result = 'deferred'
      }
    }
  }
  $script:Counts[$Result] = $script:Counts[$Result] + 1
  Write-Note "job $Id -> ${Result}: $Reason"
}

function New-Prompt([string[]]$Ids) {
  $sb = New-Object System.Text.StringBuilder
  $null = $sb.AppendLine("你是 dev-brain 的 curator，工作目录是库根 $Vault。")
  $null = $sb.AppendLine("先完整阅读 _system/rules.md 和 _system/curator-session.md，再按 curator-session.md「每次运行的处理流程」处理下面这批 handoff（共 $($Ids.Count) 条）。")
  $null = $sb.AppendLine('提交和 Git 同步由外部执行器完成：不要运行任何会修改 .git 的命令；移动文件用 mv（PowerShell 里是 Move-Item），并在 changed_paths 里同时列出旧路径和新路径。')
  $null = $sb.AppendLine('开始前看一眼 git status：tasks/、issues/ 之外如果有上一次 curator 运行中断留下的未提交改动，先检查，再决定补完还是撤回，并把这些路径也列进 changed_paths。')
  $null = $sb.AppendLine('最终回复按给定的 JSON schema 输出，jobs 里每条 handoff 一项，id 原样照抄。')
  foreach ($id in $Ids) {
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine("===== handoff id: $id =====")
    $body = [IO.File]::ReadAllText((Join-Path (Q 'running') "$id.txt"), $Utf8)
    $null = $sb.Append($body)
    if (-not $body.EndsWith("`n")) { $null = $sb.AppendLine('') }
  }
  return $sb.ToString() -replace "`r`n", "`n"
}

# Windows command-line quoting (the rules CommandLineToArgvW and the MS C runtime use).
function ConvertTo-CmdArg([string]$Arg) {
  if ($Arg -ne '' -and $Arg -notmatch '[\s"]') { return $Arg }
  $sb = New-Object System.Text.StringBuilder
  $null = $sb.Append('"')
  $slashes = 0
  foreach ($ch in $Arg.ToCharArray()) {
    if ($ch -eq '\') { $slashes++; continue }
    if ($ch -eq '"') { $null = $sb.Append('\' * ($slashes * 2 + 1)) } elseif ($slashes) { $null = $sb.Append('\' * $slashes) }
    $slashes = 0
    $null = $sb.Append($ch)
  }
  $null = $sb.Append('\' * ($slashes * 2))
  $null = $sb.Append('"')
  return $sb.ToString()
}

function Resolve-CodexExe {
  if (Test-Path -LiteralPath $CodexBin -PathType Leaf) { return (Resolve-Path -LiteralPath $CodexBin).ProviderPath }
  # Prefer a real executable or .cmd shim over npm's codex.ps1, which cannot be started as a process.
  $cmd = Get-Command $CodexBin -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd) { return $cmd.Source }
  return $null
}

function Stop-ProcessTree($Process) {
  try {
    if ($OnWindows) { $null = Invoke-Native 'taskkill' @('/PID', "$($Process.Id)", '/T', '/F') } else { $Process.Kill() }
  } catch { }
}

function Invoke-Codex([string]$PromptFile, [string]$ResultFile, [string]$EventsFile, [string]$StderrFile) {
  $exe = Resolve-CodexExe
  if (-not $exe) {
    Write-Note "codex executable not found: $CodexBin"
    return 127
  }
  $codexArgs = @(
    'exec', '--ignore-user-config', '--ephemeral', '--sandbox', 'workspace-write',
    '-C', $Vault, '-m', $Model, '-c', "model_reasoning_effort=$Effort",
    '--output-schema', $Schema, '-o', $ResultFile, '--json', '-'
  )
  $argLine = ($codexArgs | ForEach-Object { ConvertTo-CmdArg $_ }) -join ' '
  $file = $exe
  if ($exe -match '\.(cmd|bat)$') {
    $file = $env:ComSpec
    $argLine = '/d /s /c "' + (ConvertTo-CmdArg $exe) + ' ' + $argLine + '"'
  }
  $p = Start-Process -FilePath $file -ArgumentList $argLine -NoNewWindow -PassThru `
    -RedirectStandardInput $PromptFile -RedirectStandardOutput $EventsFile -RedirectStandardError $StderrFile
  $null = $p.Handle  # keeps ExitCode readable after the process exits
  if (-not $p.WaitForExit($RunTimeout * 1000)) {
    Stop-ProcessTree $p
    Write-Note "codex timed out after ${RunTimeout}s"
    return 124
  }
  $p.WaitForExit()
  return $p.ExitCode
}

function Read-CuratorResult([string]$ResultFile, [string[]]$Ids) {
  try {
    $res = [IO.File]::ReadAllText($ResultFile, $Utf8) | ConvertFrom-Json
  } catch {
    return $null
  }
  $flat = { param($t) (("$t" -split '\s+') | Where-Object { $_ }) -join ' ' }
  $jobs = @{}
  foreach ($j in @($res.jobs)) { if ($j -and $j.id) { $jobs["$($j.id)"] = $j } }
  $parsed = [pscustomobject]@{
    Jobs    = New-Object System.Collections.Generic.List[object]
    Paths   = New-Object System.Collections.Generic.List[string]
    Message = '整理 handoff'
  }
  foreach ($id in $Ids) {
    $j = $jobs[$id]
    if ($null -eq $j) {
      $parsed.Jobs.Add([pscustomobject]@{ Id = $id; Result = 'deferred'; Reason = 'missing from curator result' })
    } else {
      $r = if ($j.result) { "$($j.result)" } else { 'deferred' }
      $parsed.Jobs.Add([pscustomobject]@{ Id = $id; Result = $r; Reason = (& $flat $j.reason) })
    }
  }
  $root = $Vault.TrimEnd('\', '/')
  $cmp = if ($OnWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
  $seen = @{}
  foreach ($raw in @($res.changed_paths)) {
    $raw = "$raw".Trim()
    if (-not $raw) { continue }
    $full = if ([IO.Path]::IsPathRooted($raw)) { [IO.Path]::GetFullPath($raw) } else { [IO.Path]::GetFullPath((Join-Path $root $raw)) }
    if (-not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, $cmp)) {
      Write-Note "not committed: $raw`toutside the vault"
      continue
    }
    $rel = $full.Substring($root.Length + 1) -replace '\\', '/'
    $parts = $rel -split '/'
    if ($parts[0] -eq '.git') {
      Write-Note "not committed: $raw`toutside the vault"
    } elseif ($parts.Count -gt 2 -and $parts[0] -eq 'projects' -and $parts[2] -in 'tasks', 'issues') {
      Write-Note "not committed: $rel`towned by a work session"
    } elseif (-not $seen.ContainsKey($rel)) {
      $seen[$rel] = $true
      $parsed.Paths.Add($rel)
    }
  }
  $msg = & $flat $res.commit_message
  if ($msg) { $parsed.Message = $msg }
  return $parsed
}

function Save-CommitMessage([string]$Message) {
  $f = Join-Path (Q 'logs') "commit-msg-$($script:RunId).txt"
  Write-Text $f "$Message`n"
  return $f
}

function Invoke-CommitPaths([string]$Message, [string[]]$Paths) {
  $keep = @()
  foreach ($p in $Paths) {
    if ((Test-Path -LiteralPath (Join-Path $Vault $p)) -or (Invoke-Git @('cat-file', '-e', "HEAD:$p")).Code -eq 0) {
      $keep += $p
    } else {
      Write-Note "ignored path that neither exists nor is tracked: $p"
    }
  }
  if (-not $keep.Count) { return $true }
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    if ((Invoke-Git (@('add', '-A', '--') + $keep) -Log).Code -eq 0) { break }
    if ($attempt -eq 5) { return $false }
    Start-Sleep -Seconds 2
  }
  if ((Invoke-Git (@('diff', '--cached', '--quiet', '--') + $keep)).Code -eq 0) { return $true }
  $msgFile = Save-CommitMessage "curator: $Message"
  try {
    for ($attempt = 1; $attempt -le 5; $attempt++) {
      if ((Invoke-Git (@('commit', '-q', '-F', $msgFile, '--') + $keep) -Log).Code -eq 0) {
        $script:Commits.Add(((Invoke-Git @('rev-parse', '--short', 'HEAD')).Out | Select-Object -First 1))
        return $true
      }
      Start-Sleep -Seconds 2
    }
    return $false
  } finally {
    Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-Batch([System.IO.FileInfo[]]$Files) {
  $ids = @()
  foreach ($f in $Files) {
    $id = $f.BaseName
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $f.FullName).Hash.ToLowerInvariant()
    $prior = $null
    foreach ($h in Get-QueueFiles 'done' '*.sha256') {
      if ([IO.File]::ReadAllText($h.FullName).Trim() -eq $hash) { $prior = $h; break }
    }
    if ($prior) {
      Move-Item -LiteralPath $f.FullName -Destination (Join-Path (Q 'done') $f.Name) -Force
      Write-Text (Join-Path (Q 'done') "$id.result") "duplicate`tsame content as $($prior.BaseName)`trun=$($script:RunId)`n"
      $script:Counts['duplicate'] = $script:Counts['duplicate'] + 1
      Write-Note "job $id -> duplicate of $($prior.BaseName)"
      continue
    }
    Move-Item -LiteralPath $f.FullName -Destination (Join-Path (Q 'running') $f.Name) -Force
    Write-Text (Join-Path (Q 'running') "$id.sha256") "$hash`n"
    $ids += $id
  }
  if (-not $ids.Count) { return $true }

  $script:BatchSeq++
  $batchId = "$($script:RunId)-$($script:BatchSeq)"
  $logs = Q 'logs'
  $prompt = Join-Path $logs "run-$batchId.prompt.md"
  $result = Join-Path $logs "run-$batchId.result.json"
  $events = Join-Path $logs "run-$batchId.jsonl"
  $stderr = Join-Path $logs "run-$batchId.stderr"
  Write-Text $prompt (New-Prompt $ids)
  Write-Note "batch ${batchId}: $($ids.Count) handoff(s) with $Model/$Effort"

  $rc = Invoke-Codex $prompt $result $events $stderr
  $parsed = $null
  if ($rc -eq 0) { $parsed = Read-CuratorResult $result $ids }
  if ($rc -ne 0 -or $null -eq $parsed) {
    Write-Note "batch ${batchId}: codex exit $rc or unreadable result; handoffs go back to pending"
    foreach ($id in $ids) { Complete-Job $id 'deferred' "codex run failed (exit $rc), see logs/run-$batchId.*" }
    return $false
  }

  if (-not (Invoke-CommitPaths $parsed.Message ([string[]]$parsed.Paths))) {
    Write-Note "batch ${batchId}: commit failed; handoffs go back to pending"
    foreach ($id in $ids) { Complete-Job $id 'deferred' "commit failed, see logs/run-$batchId.*" }
    return $false
  }

  foreach ($j in $parsed.Jobs) { Complete-Job $j.Id $j.Result $j.Reason }
  return $true
}

function Sync-Vault {
  $gitdir = ((Invoke-Git @('rev-parse', '--absolute-git-dir')).Out | Select-Object -First 1)
  $inRebase = { (Test-Path -LiteralPath (Join-Path $gitdir 'rebase-merge')) -or (Test-Path -LiteralPath (Join-Path $gitdir 'rebase-apply')) }
  if ((& $inRebase) -or (Test-Path -LiteralPath (Join-Path $gitdir 'MERGE_HEAD'))) {
    $script:SyncResult = 'deferred: rebase or merge in progress'
    return
  }
  if ((Invoke-Git @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')).Code -ne 0) {
    $script:SyncResult = 'skipped: no upstream branch'
    return
  }
  $env:GIT_TERMINAL_PROMPT = '0'
  if (-not $env:GIT_SSH_COMMAND) { $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes -o ConnectTimeout=15' }
  $logName = Split-Path -Leaf $script:RunLog
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    if ((Invoke-Git @('fetch', '--quiet') -Log).Code -ne 0) {
      $script:SyncResult = "failed: fetch, see $logName"
      return
    }
    $behind = [int]((Invoke-Git @('rev-list', '--count', 'HEAD..@{u}')).Out | Select-Object -First 1)
    $ahead = [int]((Invoke-Git @('rev-list', '--count', '@{u}..HEAD')).Out | Select-Object -First 1)
    if ($behind -gt 0) {
      # Rebasing rewrites the working tree, so it needs tracked files to be clean.
      # Pushing alone does not, which is why a session's unfinished edits only
      # block sync when the remote has moved.
      $dirty = @((Invoke-Git @('status', '--porcelain', '--untracked-files=no')).Out | Where-Object { $_.Length -gt 3 } | ForEach-Object { $_.Substring(3) }) -join ' '
      if ($dirty) {
        $script:SyncResult = "deferred: remote has new commits and tracked files are modified: $dirty"
        return
      }
      if ((Invoke-Git @('rebase', '--quiet', '@{u}') -Log).Code -ne 0) {
        if (& $inRebase) {
          $conflicts = @((Invoke-Git @('diff', '--name-only', '--diff-filter=U')).Out) -join ' '
          $null = Invoke-Git @('rebase', '--abort') -Log
          $script:SyncResult = "blocked: conflict in $conflicts"
        } else {
          $script:SyncResult = "failed: rebase, see $logName"
        }
        return
      }
      $ahead = [int]((Invoke-Git @('rev-list', '--count', '@{u}..HEAD')).Out | Select-Object -First 1)
    }
    if ($ahead -eq 0) {
      $script:SyncResult = 'ok: up to date'
      return
    }
    if ((Invoke-Git @('push', '--quiet') -Log).Code -eq 0) {
      $script:SyncResult = 'ok: pushed'
      return
    }
  }
  $script:SyncResult = 'failed: push rejected 3 times'
}

function Remove-OldLogs {
  $old = @(Get-ChildItem -LiteralPath (Q 'logs') -Filter 'run-*.log' -File | Sort-Object LastWriteTimeUtc -Descending)
  if ($old.Count -le $KeepRuns) { return }
  foreach ($f in $old[$KeepRuns..($old.Count - 1)]) {
    $prefix = $f.Name.Substring(0, $f.Name.Length - 4)
    Get-ChildItem -LiteralPath (Q 'logs') -File | Where-Object { $_.Name.StartsWith($prefix) } | Remove-Item -Force
  }
}

function Write-Summary {
  $c = $script:Counts
  $line = '{0} run={1} model={2}/{3} done={4} skipped={5} duplicate={6} deferred={7} failed={8} autosaved={9} commits={10} sync={11}' -f `
    (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $script:RunId, $Model, $Effort, $c.done, $c.skipped, $c.duplicate, $c.deferred, $c.failed,
    $script:Autosaved.Count, ($script:Commits -join ','), $script:SyncResult
  [IO.File]::AppendAllText((Join-Path (Q 'logs') 'runs.log'), "$line`n", $Utf8)
  Write-Text (Join-Path (Q 'logs') 'last-run.txt') "$line`n"
  $line
  Write-Note $line
  Remove-OldLogs
}

# Commits session-owned directories (task records, issue workbenches, diagrams)
# that have uncommitted changes but have not been touched for AutosaveIdle
# seconds. Sessions are supposed to commit at their checkpoints; this catches the
# ones that stopped early or committed only part of their directory.
function Save-IdleSessions {
  $status = (Invoke-Git @('status', '--porcelain', '-z', '--untracked-files=all')).Out -join "`n"
  $dirs = [ordered]@{}
  foreach ($entry in $status -split [char]0) {
    if ($entry.Length -le 3) { continue }
    $rel = $entry.Substring(3)
    if ($rel -match '^(projects/[^/]+/(tasks|issues)/[^/]+)/') {
      $dirs[$Matches[1]] = $true
    } elseif ($rel -match '^(projects/[^/]+/diagrams)/') {
      $dirs[$Matches[1]] = $true
    }
  }
  $now = (Get-Date).ToUniversalTime()
  foreach ($dir in @($dirs.Keys)) {
    $files = @(Get-ChildItem -LiteralPath (Join-Path $Vault $dir) -Recurse -File -ErrorAction SilentlyContinue)
    $newest = [datetime]::MinValue
    foreach ($f in $files) { if ($f.LastWriteTimeUtc -gt $newest) { $newest = $f.LastWriteTimeUtc } }
    if (($now - $newest).TotalSeconds -lt $AutosaveIdle) {
      Write-Note "autosave: $dir still active, skipped"
      continue
    }
    if ((Invoke-Git @('add', '-A', '--', $dir) -Log).Code -ne 0) { continue }
    if ((Invoke-Git @('diff', '--cached', '--quiet', '--', $dir)).Code -eq 0) { continue }
    $msgFile = Save-CommitMessage "autosave: $dir (会话未提交，curator 补提交)"
    if ((Invoke-Git @('commit', '-q', '-F', $msgFile, '--', $dir) -Log).Code -eq 0) {
      $script:Commits.Add(((Invoke-Git @('rev-parse', '--short', 'HEAD')).Out | Select-Object -First 1))
      $script:Autosaved.Add($dir)
    }
    Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-RunCommand {
  if (-not (Test-Path -LiteralPath $Schema)) { Stop-WithError "missing schema: $Schema" }
  Start-Run
  Invoke-RequeueRunning
  while ($true) {
    $batch = @(Get-QueueFiles 'pending' | Select-Object -First $BatchSize)
    if (-not $batch.Count) { break }
    if (-not (Invoke-Batch $batch)) { break }
  }
  Save-IdleSessions
  Sync-Vault
  Write-Summary
}

function Invoke-SyncCommand {
  Start-Run
  Sync-Vault
  "sync: $($script:SyncResult)"
  if (-not ($script:SyncResult -like 'ok:*' -or $script:SyncResult -like 'skipped:*')) { $script:ExitCode = 1 }
}

function Show-Status {
  Initialize-Dirs
  "vault: $Vault"
  "queue: $QueueDir"
  'pending: {0}  running: {1}  done: {2}  failed: {3}' -f (Get-QueueFiles 'pending').Count, (Get-QueueFiles 'running').Count, (Get-QueueFiles 'done').Count, (Get-QueueFiles 'failed').Count
  if (Test-Path -LiteralPath $LockDir) {
    $lockPid = Get-LockPid
    if (Test-PidAlive $lockPid) { "lock: held by running pid $lockPid" } else { "lock: stale (pid $(if ($null -ne $lockPid) { $lockPid } else { 'unknown' })); the next run recovers it" }
  } else {
    'lock: free'
  }
  "model: $Model / $Effort"
  if ($OnWindows) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) { "scheduled task: $($task.State) ($TaskName)" } else { 'scheduled task: not installed (run: dev-brain-curator.ps1 install)' }
  } else {
    'scheduled task: not available on this platform (macOS uses _system/bin/dev-brain-curator)'
  }
  $last = Join-Path (Q 'logs') 'last-run.txt'
  "last run: $(if (Test-Path -LiteralPath $last) { [IO.File]::ReadAllText($last, $Utf8).Trim() } else { 'none' })"
}

function Install-Task {
  if (-not $OnWindows) { Stop-WithError 'install registers a Windows scheduled task; on macOS use _system/bin/dev-brain-curator install' }
  $codex = Resolve-CodexExe
  if (-not $codex) { Stop-WithError "codex executable not found: $CodexBin (set CODEX_BIN in $ConfigFile)" }
  Initialize-Dirs
  $psExe = (Get-Process -Id $PID).Path
  $arg = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File {0} run' -f (ConvertTo-CmdArg $ScriptPath)
  $action = New-ScheduledTaskAction -Execute $psExe -Argument $arg -WorkingDirectory $Vault
  $hourly = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Seconds $Interval)
  $logon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
  $settings = New-ScheduledTaskSettingsSet -MultipleInstances Queue -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds ($RunTimeout * 4))
  $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
  $null = Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($hourly, $logon) -Settings $settings `
    -Principal $principal -Description 'dev-brain curator: drains the handoff queue and syncs the vault' -Force
  "installed: scheduled task $TaskName"
  "runs: hourly every ${Interval}s, at logon, and after each dev-brain-handoff.ps1 enqueue; codex $codex; model $Model / $Effort"
}

function Uninstall-Task {
  if (-not $OnWindows) { Stop-WithError 'uninstall removes a Windows scheduled task; on macOS use _system/bin/dev-brain-curator uninstall' }
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
  }
  "uninstalled: scheduled task $TaskName"
}

$script:ExitCode = 0
try {
  switch ($Command) {
    'run' { Invoke-RunCommand }
    'sync' { Invoke-SyncCommand }
    'status' { Show-Status }
    'install' { Install-Task }
    'uninstall' { Uninstall-Task }
    { $_ -in '-h', '--help', 'help', '' } { Exit-Usage 0 }
    default { Exit-Usage 64 }
  }
} finally {
  Exit-Lock
}
exit $script:ExitCode
