#Requires -Version 5.1
# Tests for _system/bin/dev-brain-curator.ps1 with a fake codex. Needs git.
# Run: powershell -ExecutionPolicy Bypass -File test-dev-brain-curator.ps1
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
$Curator = Join-Path $Root '_system/bin/dev-brain-curator.ps1'
$Handoff = Join-Path $Root '_system/bin/dev-brain-handoff.ps1'
$PsExe = (Get-Process -Id $PID).Path
$OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("dbc-test-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $Tmp
$Utf8 = New-Object System.Text.UTF8Encoding $false
$FakeLog = Join-Path $Tmp 'codex.calls'
$env:DEV_BRAIN_HANDOFF_NO_TRIGGER = '1'

# The fake codex writes one note per handoff id and reports it, like a real curator run.
$FakePs1 = Join-Path $Tmp 'fake-codex.ps1'
$fakeBody = @'
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
$out = $null; $vault = $null
for ($i = 0; $i -lt $args.Count; $i++) {
  if ($args[$i] -eq '-o') { $out = $args[$i + 1] }
  if ($args[$i] -eq '-C') { $vault = $args[$i + 1] }
}
[IO.File]::AppendAllText($env:FAKE_LOG, ($args -join ' ') + "`n", $utf8)
[Console]::InputEncoding = $utf8
$prompt = [Console]::In.ReadToEnd()
if ($env:FAKE_FAIL -eq '1') { exit 3 }
$result = if ($env:FAKE_RESULT) { $env:FAKE_RESULT } else { 'done' }
$paths = @(); $jobs = @()
foreach ($m in [regex]::Matches($prompt, '(?m)^===== handoff id: (.*) =====\r?$')) {
  $id = $m.Groups[1].Value
  $note = "knowledge/fake-$id.md"
  [IO.File]::WriteAllText((Join-Path $vault $note), "---`nproject: knowledge`nsource: test`nstatus: draft`n---`n`n# $id`n", $utf8)
  $paths += $note
  $jobs += [ordered]@{ id = $id; result = $result; actions = @(@{ action = '新建'; path = $note }); reason = 'fake' }
}
if ($env:FAKE_TOUCH_TASK -eq '1') {
  [IO.File]::AppendAllText((Join-Path $vault 'projects/p1/tasks/t1/record.md'), "curator edit`n", $utf8)
  $paths += 'projects/p1/tasks/t1/record.md'
}
if ($env:FAKE_HUB_LINE) {
  $hub = Join-Path $vault 'projects/p1/_hub.md'
  $text = [IO.File]::ReadAllText($hub, $utf8).Replace("## 当前状态`n", "## 当前状态`n`n- $($env:FAKE_HUB_LINE)`n")
  [IO.File]::WriteAllText($hub, $text, $utf8)
  $paths += 'projects/p1/_hub.md'
}
$json = [ordered]@{ jobs = @($jobs); changed_paths = @($paths); commit_message = 'fake curation'; summary = 'ok' } | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText($out, $json, $utf8)
'{"type":"done"}'
'@
if ($OnWindows) {
  [IO.File]::WriteAllText($FakePs1, $fakeBody, (New-Object System.Text.UTF8Encoding $true))
  $FakeCodex = Join-Path $Tmp 'fake-codex.cmd'
  [IO.File]::WriteAllText($FakeCodex, "@`"$PsExe`" -NoProfile -ExecutionPolicy Bypass -File `"$FakePs1`" %*`r`n", $Utf8)
} else {
  $FakeCodex = $FakePs1
  [IO.File]::WriteAllText($FakePs1, "#!$PsExe`n" + $fakeBody, $Utf8)
  & chmod +x $FakePs1
}

function Assert-Eq($Expected, $Actual, [string]$What) {
  if ("$Expected" -ne "$Actual") { throw "expected $What to be '$Expected', got '$Actual'" }
}
function Assert-True($Cond, [string]$What) { if (-not $Cond) { throw "assertion failed: $What" } }
function Count-Txt([string]$Dir) {
  if (-not (Test-Path -LiteralPath $Dir)) { return 0 }
  return @(Get-ChildItem -LiteralPath $Dir -Filter '*.txt' -File).Count
}
function G {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = & git -c user.name=test -c user.email=test@example.com -c core.quotepath=false @args 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $prev }
  if ($LASTEXITCODE -ne 0) { throw "git $args failed: $o" }
  return $o
}
function Write-Utf8([string]$Path, [string]$Text) {
  $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)
  [IO.File]::WriteAllText($Path, $Text, $Utf8)
}
function Set-Old([string]$Path) { (Get-Item -LiteralPath $Path).LastWriteTime = [datetime]'2026-01-01' }

# Creates $Tmp/<name>/{remote.git,vault,queue} with a pushed initial commit.
function New-Case([string]$Name) {
  $base = Join-Path $Tmp $Name
  $vault = Join-Path $base 'vault'
  $null = New-Item -ItemType Directory -Force -Path $vault
  G init -q --bare (Join-Path $base 'remote.git') | Out-Null
  G -C (Join-Path $base 'remote.git') symbolic-ref HEAD refs/heads/master | Out-Null
  G init -q $vault | Out-Null
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $vault '_system'), (Join-Path $vault 'knowledge'), (Join-Path $vault 'projects/p1/tasks/t1')
  Copy-Item (Join-Path $Root '_system/curator-output.schema.json') (Join-Path $vault '_system/')
  Copy-Item (Join-Path $Root '.gitattributes') $vault
  Write-Utf8 (Join-Path $vault 'projects/p1/_hub.md') "# p1`n`n## 当前状态`n`n- 2026-01-01：初始`n"
  Write-Utf8 (Join-Path $vault 'projects/p1/tasks/t1/record.md') "task record`n"
  G -C $vault config core.autocrlf false | Out-Null
  G -C $vault add -A | Out-Null
  G -C $vault commit -q -m init | Out-Null
  G -C $vault branch -M master | Out-Null
  G -C $vault remote add origin (Join-Path $base 'remote.git') | Out-Null
  G -C $vault push -q -u origin master | Out-Null
  G -C $vault config user.name test | Out-Null
  G -C $vault config user.email test@example.com | Out-Null
  return $base
}

function Add-Handoff([string]$Base, [string]$Body) {
  $null = "dev-brain handoff`nproject: p1`nkind: research`nsource: test`nkeywords: k`nsummary: $Body`n" | & $Handoff -QueueDir (Join-Path $Base 'queue')
}

function Invoke-Curator([string]$Base, [hashtable]$Extra = @{}) {
  $envs = @{
    DEV_BRAIN_VAULT = (Join-Path $Base 'vault'); DEV_BRAIN_HANDOFF_QUEUE = (Join-Path $Base 'queue')
    DEV_BRAIN_CURATOR_CONFIG = (Join-Path $Tmp 'nonexistent.env'); CODEX_BIN = $FakeCodex; FAKE_LOG = $FakeLog
    DEV_BRAIN_CURATOR_LOCK_WAIT = '4'
  }
  foreach ($k in $Extra.Keys) { $envs[$k] = $Extra[$k] }
  $saved = @{}
  foreach ($k in $envs.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $envs[$k]) }
  try {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & $PsExe -NoProfile -ExecutionPolicy Bypass -File $Curator run 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
  } finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
  }
  return [pscustomobject]@{ Code = $code; Out = ($out -join "`n") }
}

function Get-LastRun([string]$Base) { [IO.File]::ReadAllText((Join-Path $Base 'queue/logs/last-run.txt'), $Utf8) }
function Get-HeadFiles([string]$Base) { G -C (Join-Path $Base 'vault') show --name-only --format= HEAD }

function Test-CommitsOnlyReportedPathsAndPushesDespiteSessionEdits {
  $b = New-Case 'dirty'
  Add-Handoff $b 'first'; Add-Handoff $b 'second'
  [IO.File]::AppendAllText((Join-Path $b 'vault/projects/p1/tasks/t1/record.md'), "session edit`n", $Utf8)
  $r = Invoke-Curator $b
  Assert-Eq 0 $r.Code "curator exit ($($r.Out))"
  Assert-Eq 0 (Count-Txt (Join-Path $b 'queue/pending')) 'pending after run'
  Assert-Eq 2 (Count-Txt (Join-Path $b 'queue/done')) 'done after run'
  Assert-Eq 'curator: fake curation' (G -C (Join-Path $b 'vault') log -1 --format=%s) 'commit subject'
  $files = @(Get-HeadFiles $b)
  Assert-Eq 2 @($files | Where-Object { $_ -like 'knowledge/fake-*' }).Count 'files in curator commit'
  Assert-True (-not ($files -match 'tasks/')) 'curator did not commit a session file'
  Assert-True (@(G -C (Join-Path $b 'vault') status --porcelain -- projects/p1/tasks/t1/record.md).Count -gt 0) 'session edit kept'
  $last = Get-LastRun $b
  Assert-True ($last -match 'done=2 ') "last run done=2: $last"
  Assert-True ($last -match 'sync=ok: pushed') "last run pushed: $last"
  Assert-Eq 'curator: fake curation' (G -C (Join-Path $b 'remote.git') log -1 --format=%s master) 'remote head'
}

function Test-DefersSyncWhenRemoteMovedAndTreeDirty {
  $b = New-Case 'moved'
  $other = Join-Path $b 'other'
  G clone -q (Join-Path $b 'remote.git') $other | Out-Null
  Write-Utf8 (Join-Path $other 'remote-note.md') "remote change`n"
  G -C $other add -A | Out-Null; G -C $other commit -q -m 'other machine' | Out-Null; G -C $other push -q | Out-Null
  Add-Handoff $b 'moved'
  [IO.File]::AppendAllText((Join-Path $b 'vault/projects/p1/tasks/t1/record.md'), "session edit`n", $Utf8)
  $null = Invoke-Curator $b
  $last = Get-LastRun $b
  Assert-True ($last -match 'sync=deferred: remote has new commits and tracked files are modified: projects/p1/tasks/t1/record.md') "deferred sync: $last"
}

function Test-AutosavesIdleSessionDirsOnly {
  $b = New-Case 'autosave'
  $v = Join-Path $b 'vault'
  Write-Utf8 (Join-Path $v 'projects/p1/tasks/t1/artifacts-note.md') "old draft`n"
  Write-Utf8 (Join-Path $v 'projects/p1/tasks/t2/artifacts/shot.txt') "old shot`n"
  Set-Old (Join-Path $v 'projects/p1/tasks/t1/record.md'); Set-Old (Join-Path $v 'projects/p1/tasks/t1/artifacts-note.md'); Set-Old (Join-Path $v 'projects/p1/tasks/t2/artifacts/shot.txt')
  Write-Utf8 (Join-Path $v 'projects/p1/tasks/t3/record.md') "being written`n"
  $null = Invoke-Curator $b @{ DEV_BRAIN_CURATOR_AUTOSAVE_IDLE = '600' }
  $last = Get-LastRun $b
  Assert-True ($last -match 'autosaved=2 ') "autosaved=2: $last"
  Assert-True ($last -match 'sync=ok: pushed') "pushed: $last"
  $log = @(G -C (Join-Path $b 'remote.git') log --format=%s master)
  Assert-True (@($log | Where-Object { $_ -like 'autosave: projects/p1/tasks/t1*' }).Count -eq 1) 't1 autosaved'
  Assert-True (@($log | Where-Object { $_ -like 'autosave: projects/p1/tasks/t2*' }).Count -eq 1) 't2 autosaved'
  Assert-True (@($log | Where-Object { $_ -like '*tasks/t3*' }).Count -eq 0) 'active t3 not autosaved'
}

function Test-DuplicateContentSkipsCodex {
  $b = New-Case 'dup'
  [IO.File]::WriteAllText($FakeLog, '', $Utf8)
  Add-Handoff $b 'same'; $null = Invoke-Curator $b
  Add-Handoff $b 'same'; $null = Invoke-Curator $b
  Assert-Eq 1 @([IO.File]::ReadAllLines($FakeLog) | Where-Object { $_ }).Count 'codex calls for duplicate content'
  Assert-Eq 2 (Count-Txt (Join-Path $b 'queue/done')) 'done after duplicate'
  Assert-True (@(Get-ChildItem (Join-Path $b 'queue/done') -Filter '*.result' | Where-Object { [IO.File]::ReadAllText($_.FullName) -like 'duplicate*' }).Count -eq 1) 'duplicate result'
}

function Test-FailureRequeuesThenGivesUp {
  $b = New-Case 'fail'
  Add-Handoff $b 'broken'
  $null = Invoke-Curator $b @{ FAKE_FAIL = '1'; DEV_BRAIN_CURATOR_MAX_ATTEMPTS = '2' }
  Assert-Eq 1 (Count-Txt (Join-Path $b 'queue/pending')) 'pending after first failure'
  Assert-Eq 0 (Count-Txt (Join-Path $b 'queue/running')) 'running after first failure'
  $null = Invoke-Curator $b @{ FAKE_FAIL = '1'; DEV_BRAIN_CURATOR_MAX_ATTEMPTS = '2' }
  Assert-Eq 0 (Count-Txt (Join-Path $b 'queue/pending')) 'pending after second failure'
  Assert-Eq 1 (Count-Txt (Join-Path $b 'queue/failed')) 'failed after second failure'
  Assert-True ((Get-LastRun $b) -match 'failed=1') 'last run failed=1'
}

function Test-SessionPathsAreNeverCommitted {
  $b = New-Case 'session'
  Add-Handoff $b 'touch task'
  $null = Invoke-Curator $b @{ FAKE_TOUCH_TASK = '1' }
  Assert-True (-not (@(Get-HeadFiles $b) -match 'tasks/')) 'session-owned path not committed'
  $logs = Get-ChildItem (Join-Path $b 'queue/logs') -Filter 'run-*.log' | ForEach-Object { [IO.File]::ReadAllText($_.FullName, $Utf8) }
  Assert-True (($logs -join '') -match 'owned by a work session') 'skip reason logged'
}

function Test-LiveLockBlocksSecondRun {
  $b = New-Case 'locked'
  Add-Handoff $b 'waiting'
  $sleepArgs = @{ FilePath = $PsExe; ArgumentList = '-NoProfile -Command Start-Sleep -Seconds 60'; PassThru = $true }
  if ($OnWindows) { $sleepArgs['WindowStyle'] = 'Hidden' }
  $sleeper = Start-Process @sleepArgs
  try {
    $lock = Join-Path $b 'queue/.worker.lock'
    $null = New-Item -ItemType Directory -Force -Path $lock
    Write-Utf8 (Join-Path $lock 'pid') "$($sleeper.Id)`n"
    $r = Invoke-Curator $b
    Assert-Eq 75 $r.Code 'exit status while another run holds the lock'
    Assert-Eq 1 (Count-Txt (Join-Path $b 'queue/pending')) 'pending while locked'
  } finally {
    Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue
  }
}

function Test-StaleLockIsRecovered {
  $b = New-Case 'stale'
  Add-Handoff $b 'after crash'
  $lock = Join-Path $b 'queue/.worker.lock'
  $null = New-Item -ItemType Directory -Force -Path $lock, (Join-Path $b 'queue/running')
  Write-Utf8 (Join-Path $lock 'pid') "999999`n"
  Set-Old $lock
  $null = Invoke-Curator $b
  Assert-Eq 1 (Count-Txt (Join-Path $b 'queue/done')) 'done after stale lock recovery'
  Assert-True (-not (Test-Path -LiteralPath $lock)) 'stale lock removed'
}

function Test-ConcurrentHubAppendsMergeWithoutConflict {
  $b = New-Case 'hub'
  $other = Join-Path $b 'other'
  G clone -q (Join-Path $b 'remote.git') $other | Out-Null
  G -C $other config core.autocrlf false | Out-Null
  $hub = Join-Path $other 'projects/p1/_hub.md'
  Write-Utf8 $hub ([IO.File]::ReadAllText($hub, $Utf8).Replace("## 当前状态`n", "## 当前状态`n`n- 来自另一台机器`n"))
  G -C $other commit -q -am 'other machine' | Out-Null; G -C $other push -q | Out-Null
  Add-Handoff $b 'hub'
  $null = Invoke-Curator $b @{ FAKE_HUB_LINE = '来自本机 curator' }
  $last = Get-LastRun $b
  Assert-True ($last -match 'sync=ok: pushed') "pushed after hub merge: $last"
  $merged = (G -C (Join-Path $b 'remote.git') show master:projects/p1/_hub.md) -join "`n"
  Assert-True ($merged.Contains('来自另一台机器')) 'other machine line kept'
  Assert-True ($merged.Contains('来自本机 curator')) 'local curator line kept'
}

try {
  Test-CommitsOnlyReportedPathsAndPushesDespiteSessionEdits
  Test-DefersSyncWhenRemoteMovedAndTreeDirty
  Test-AutosavesIdleSessionDirsOnly
  Test-DuplicateContentSkipsCodex
  Test-FailureRequeuesThenGivesUp
  Test-SessionPathsAreNeverCommitted
  Test-LiveLockBlocksSecondRun
  Test-StaleLockIsRecovered
  Test-ConcurrentHubAppendsMergeWithoutConflict
  'dev-brain-curator.ps1 tests passed'
} finally {
  Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}
