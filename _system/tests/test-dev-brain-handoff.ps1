#Requires -Version 5.1
# Tests for _system/bin/dev-brain-handoff.ps1. Run: powershell -ExecutionPolicy Bypass -File test-dev-brain-handoff.ps1
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
$Script = Join-Path $Root '_system/bin/dev-brain-handoff.ps1'
$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("dbh-test-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $Tmp
$Utf8 = New-Object System.Text.UTF8Encoding $false
$env:DEV_BRAIN_HANDOFF_NO_TRIGGER = '1'

$Handoff = "dev-brain handoff`nproject: knowledge`nkind: research`nsource: test-repo@abc123:path/to/file`nkeywords: 测试 curator queue`nsummary: test handoff`n"

function Assert-Eq($Expected, $Actual, [string]$What) {
  if ("$Expected" -ne "$Actual") { throw "expected $What to be '$Expected', got '$Actual'" }
}
function Assert-True($Cond, [string]$What) { if (-not $Cond) { throw "assertion failed: $What" } }
function Count-Txt([string]$Dir) {
  if (-not (Test-Path -LiteralPath $Dir)) { return 0 }
  return @(Get-ChildItem -LiteralPath $Dir -Filter '*.txt' -File).Count
}
function New-Queue([string]$Name) {
  $q = Join-Path $Tmp $Name
  foreach ($d in 'pending', 'running', 'done', 'failed', 'logs') { $null = New-Item -ItemType Directory -Force -Path (Join-Path $q $d) }
  return $q
}

function Test-InvalidInput {
  $q = Join-Path $Tmp 'q-invalid'
  $out = "not a handoff`n" | & $Script -QueueDir $q 2>$null
  Assert-Eq 2 $LASTEXITCODE 'invalid input exit status'
  Assert-Eq 1 (Count-Txt (Join-Path $q 'failed')) 'invalid failed file count'
}

function Test-EnqueueWritesPendingOnly {
  $q = Join-Path $Tmp 'q-enqueue'
  $out = $Handoff | & $Script -QueueDir $q
  Assert-Eq 0 $LASTEXITCODE 'enqueue exit status'
  Assert-True ("$out" -match '^queued: ') 'queued line'
  Assert-Eq 1 (Count-Txt (Join-Path $q 'pending')) 'pending after enqueue'
  Assert-Eq 0 (Count-Txt (Join-Path $q 'running')) 'running after enqueue'
  $file = Get-ChildItem -LiteralPath (Join-Path $q 'pending') -Filter '*.txt' | Select-Object -First 1
  Assert-Eq $Handoff ([IO.File]::ReadAllText($file.FullName, $Utf8)) 'queued content (UTF-8, LF)'
  $bytes = [IO.File]::ReadAllBytes($file.FullName)
  Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'queued file has no BOM'
}

function Test-EnqueueFromHereStringAndFile {
  $q = Join-Path $Tmp 'q-herestring'
  $null = @'
dev-brain handoff
project: knowledge
summary: here-string
'@ | & $Script -QueueDir $q
  Assert-Eq 0 $LASTEXITCODE 'here-string enqueue exit status'
  $src = Join-Path $Tmp 'handoff.txt'
  [IO.File]::WriteAllText($src, ($Handoff -replace "`n", "`r`n"), $Utf8)
  $null = & $Script -QueueDir $q -InputFile $src
  Assert-Eq 0 $LASTEXITCODE '-InputFile enqueue exit status'
  Assert-Eq 2 (Count-Txt (Join-Path $q 'pending')) 'pending after here-string and file'
  $texts = Get-ChildItem -LiteralPath (Join-Path $q 'pending') -Filter '*.txt' | ForEach-Object { [IO.File]::ReadAllText($_.FullName, $Utf8) }
  Assert-True (-not ($texts -join '').Contains("`r")) 'CRLF normalized to LF'
}

function Test-StatusReportsCountsAndLock {
  $q = Join-Path $Tmp 'q-status'
  $null = $Handoff | & $Script -QueueDir $q
  $out = & $Script -QueueDir $q -Status
  Assert-True ($out -contains 'pending: 1') 'status pending line'
  Assert-True ($out -contains 'lock: absent') 'status lock line'
}

function Test-RecoverStaleLockRequeuesRunningJob {
  $q = New-Queue 'q-recover'
  [IO.File]::WriteAllText((Join-Path $q 'running/stuck.txt'), $Handoff, $Utf8)
  $null = New-Item -ItemType Directory -Path (Join-Path $q '.worker.lock')
  $out = & $Script -QueueDir $q -RecoverStale -StaleMinutes 0
  Assert-Eq 1 (Count-Txt (Join-Path $q 'pending')) 'pending after stale recovery'
  Assert-Eq 0 (Count-Txt (Join-Path $q 'running')) 'running after stale recovery'
  Assert-True (-not (Test-Path (Join-Path $q '.worker.lock'))) 'lock removed'
  Assert-True ("$out" -like 'recovered stale worker lock:*') 'recover message'
}

function Test-RecoverOrphanedRunningJobWithoutLock {
  $q = New-Queue 'q-orphan'
  [IO.File]::WriteAllText((Join-Path $q 'running/orphan.txt'), $Handoff, $Utf8)
  $out = & $Script -QueueDir $q -RecoverStale -StaleMinutes 0
  Assert-Eq 1 (Count-Txt (Join-Path $q 'pending')) 'pending after orphan recovery'
  Assert-Eq 'recovered orphaned running jobs' "$out" 'orphan message'
}

function Test-RecoverRefusesLiveLock {
  $q = New-Queue 'q-live'
  $null = New-Item -ItemType Directory -Path (Join-Path $q '.worker.lock')
  [IO.File]::WriteAllText((Join-Path $q '.worker.lock/pid'), "$PID`n", $Utf8)
  [IO.File]::WriteAllText((Join-Path $q 'running/busy.txt'), $Handoff, $Utf8)
  $out = & $Script -QueueDir $q -RecoverStale -StaleMinutes 0
  Assert-Eq 1 $LASTEXITCODE 'recover exit status with a live lock'
  Assert-Eq 1 (Count-Txt (Join-Path $q 'running')) 'running with a live lock'
  Assert-True ("$out" -like 'curator still running: pid*') 'live lock message'
}

try {
  Test-InvalidInput
  Test-EnqueueWritesPendingOnly
  Test-EnqueueFromHereStringAndFile
  Test-StatusReportsCountsAndLock
  Test-RecoverStaleLockRequeuesRunningJob
  Test-RecoverOrphanedRunningJobWithoutLock
  Test-RecoverRefusesLiveLock
  'dev-brain-handoff.ps1 tests passed'
} finally {
  Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}
