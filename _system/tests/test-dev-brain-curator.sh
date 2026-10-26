#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CURATOR="$ROOT/_system/bin/dev-brain-curator"
HANDOFF="$ROOT/_system/bin/dev-brain-handoff"
TMPDIR="$(mktemp -d)"
trap 'kill "${SLEEPER_PID:-}" 2>/dev/null || true; rm -rf "$TMPDIR"' EXIT

FAKE_CODEX="$TMPDIR/fake-codex"
FAKE_LOG="$TMPDIR/codex.calls"
cat > "$FAKE_CODEX" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
out=""
vault=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -o) out="${args[$((i + 1))]}" ;;
    -C) vault="${args[$((i + 1))]}" ;;
  esac
done
printf '%s\n' "$*" >> "$FAKE_LOG"
prompt="$(cat)"
if [[ "${FAKE_FAIL:-0}" == "1" ]]; then
  exit 3
fi
paths=()
jobs=()
while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  note="knowledge/fake-$id.md"
  printf -- '---\nproject: knowledge\nsource: test\nstatus: draft\n---\n\n# %s\n' "$id" > "$vault/$note"
  paths+=("\"$note\"")
  jobs+=("{\"id\":\"$id\",\"result\":\"${FAKE_RESULT:-done}\",\"actions\":[{\"action\":\"新建\",\"path\":\"$note\"}],\"reason\":\"fake\"}")
done < <(printf '%s\n' "$prompt" | sed -n 's/^===== handoff id: \(.*\) =====$/\1/p')
if [[ "${FAKE_TOUCH_TASK:-0}" == "1" ]]; then
  echo "curator edit" >> "$vault/projects/p1/tasks/t1/record.md"
  paths+=("\"projects/p1/tasks/t1/record.md\"")
fi
if [[ "${FAKE_HUB_LINE:-}" != "" ]]; then
  sed -i '' "s/^## 当前状态$/## 当前状态\n\n- ${FAKE_HUB_LINE}/" "$vault/projects/p1/_hub.md"
  paths+=("\"projects/p1/_hub.md\"")
fi
(IFS=,; printf '{"jobs":[%s],"changed_paths":[%s],"commit_message":"fake curation","summary":"ok"}' "${jobs[*]}" "${paths[*]}") > "$out"
FAKE
chmod +x "$FAKE_CODEX"

assert_eq() {
  if [[ "$1" != "$2" ]]; then
    echo "expected $3 to be '$1', got '$2'" >&2
    exit 1
  fi
}

count_files() {
  find "$1" -type f -name '*.txt' 2>/dev/null | wc -l | tr -d ' '
}

git_q() {
  git -c user.name=test -c user.email=test@example.com "$@"
}

# Creates $TMPDIR/<name>/{remote.git,vault,queue} with a pushed initial commit.
setup_case() {
  local base="$TMPDIR/$1"
  mkdir -p "$base"
  git init -q --bare -b master "$base/remote.git"
  git init -q "$base/vault"
  mkdir -p "$base/vault/_system" "$base/vault/knowledge" "$base/vault/projects/p1/tasks/t1"
  cp "$ROOT/_system/curator-output.schema.json" "$base/vault/_system/"
  cp "$ROOT/.gitattributes" "$base/vault/"
  printf '# p1\n\n## 当前状态\n\n- 2026-01-01：初始\n' > "$base/vault/projects/p1/_hub.md"
  printf 'task record\n' > "$base/vault/projects/p1/tasks/t1/record.md"
  git_q -C "$base/vault" add -A
  git_q -C "$base/vault" commit -q -m init
  git -C "$base/vault" branch -M master
  git -C "$base/vault" remote add origin "$base/remote.git"
  git -C "$base/vault" push -q -u origin master
  git -C "$base/vault" config user.name test
  git -C "$base/vault" config user.email test@example.com
  echo "$base"
}

enqueue() {
  local queue="$1" body="$2"
  printf 'dev-brain handoff\nproject: p1\nkind: research\nsource: test\nkeywords: k\nsummary: %s\n' "$body" | "$HANDOFF" --queue-dir "$queue" >/dev/null
}

run_curator() {
  local base="$1"
  shift
  env DEV_BRAIN_VAULT="$base/vault" DEV_BRAIN_HANDOFF_QUEUE="$base/queue" \
    DEV_BRAIN_CURATOR_CONFIG=/nonexistent CODEX_BIN="$FAKE_CODEX" FAKE_LOG="$FAKE_LOG" \
    DEV_BRAIN_CURATOR_NOTIFY=0 DEV_BRAIN_CURATOR_LOCK_WAIT=4 "$@" \
    "$CURATOR" run
}

last_run() {
  cat "$1/queue/logs/last-run.txt"
}

commits_only_reported_paths_and_pushes_despite_session_edits() {
  local base
  base="$(setup_case dirty)"
  enqueue "$base/queue" "first"
  enqueue "$base/queue" "second"
  echo "session edit" >> "$base/vault/projects/p1/tasks/t1/record.md"

  run_curator "$base" >/dev/null

  assert_eq 0 "$(count_files "$base/queue/pending")" "pending after run"
  assert_eq 2 "$(count_files "$base/queue/done")" "done after run"
  assert_eq "curator: fake curation" "$(git -C "$base/vault" log -1 --format=%s)" "commit subject"
  assert_eq 2 "$(git -C "$base/vault" show --name-only --format= HEAD | grep -c '^knowledge/fake-')" "files in curator commit"
  git -C "$base/vault" show --name-only --format= HEAD | grep -q 'tasks/' && { echo "curator committed a session file" >&2; exit 1; }
  git -C "$base/vault" diff --quiet -- projects/p1/tasks/t1/record.md && { echo "session edit was lost" >&2; exit 1; }
  last_run "$base" | grep -q 'done=2 '
  last_run "$base" | grep -q 'sync=ok: pushed'
  assert_eq "curator: fake curation" "$(git -C "$base/remote.git" log -1 --format=%s master)" "remote head with session edits pending"
}

defers_sync_when_remote_moved_and_tree_dirty() {
  local base other
  base="$(setup_case moved)"
  other="$base/other"
  git clone -q "$base/remote.git" "$other"
  echo "remote change" > "$other/remote-note.md"
  git_q -C "$other" add -A
  git_q -C "$other" commit -q -m "other machine"
  git -C "$other" push -q
  enqueue "$base/queue" "moved"
  echo "session edit" >> "$base/vault/projects/p1/tasks/t1/record.md"

  run_curator "$base" >/dev/null

  last_run "$base" | grep -q 'sync=deferred: remote has new commits and tracked files are modified: projects/p1/tasks/t1/record.md'
  if git -C "$base/vault" diff --quiet -- projects/p1/tasks/t1/record.md; then
    echo "session edit was lost" >&2
    exit 1
  fi
}

autosaves_idle_session_dirs_only() {
  local base
  base="$(setup_case autosave)"
  mkdir -p "$base/vault/projects/p1/tasks/t2/artifacts"
  echo "old draft" > "$base/vault/projects/p1/tasks/t1/artifacts-note.md"
  echo "old shot" > "$base/vault/projects/p1/tasks/t2/artifacts/shot.txt"
  touch -t 202601010000 "$base/vault/projects/p1/tasks/t1/record.md" "$base/vault/projects/p1/tasks/t1/artifacts-note.md" "$base/vault/projects/p1/tasks/t2/artifacts/shot.txt"
  mkdir -p "$base/vault/projects/p1/tasks/t3"
  echo "being written" > "$base/vault/projects/p1/tasks/t3/record.md"

  run_curator "$base" DEV_BRAIN_CURATOR_AUTOSAVE_IDLE=600 >/dev/null

  last_run "$base" | grep -q 'autosaved=2 '
  last_run "$base" | grep -q 'sync=ok: pushed'
  local log
  log="$(git -C "$base/remote.git" log --format=%s master)"
  grep -q '^autosave: projects/p1/tasks/t1' <<< "$log"
  grep -q '^autosave: projects/p1/tasks/t2' <<< "$log"
  if grep -q 'tasks/t3' <<< "$log"; then
    echo "active task dir was autosaved" >&2
    exit 1
  fi
  [[ -n "$(git -C "$base/vault" status --porcelain -- projects/p1/tasks/t3)" ]]
}

pushes_when_clean() {
  local base
  base="$(setup_case clean)"
  enqueue "$base/queue" "push me"

  run_curator "$base" >/dev/null

  assert_eq "curator: fake curation" "$(git -C "$base/remote.git" log -1 --format=%s master)" "remote head after run"
  last_run "$base" | grep -q 'sync=ok: pushed'
}

duplicate_content_skips_codex() {
  local base
  base="$(setup_case dup)"
  : > "$FAKE_LOG"
  enqueue "$base/queue" "same"
  run_curator "$base" >/dev/null
  enqueue "$base/queue" "same"
  run_curator "$base" >/dev/null

  assert_eq 1 "$(wc -l < "$FAKE_LOG" | tr -d ' ')" "codex calls for duplicate content"
  assert_eq 2 "$(count_files "$base/queue/done")" "done after duplicate"
  grep -q '^duplicate' "$base"/queue/done/*.result
}

failure_requeues_then_gives_up() {
  local base
  base="$(setup_case fail)"
  enqueue "$base/queue" "broken"

  run_curator "$base" FAKE_FAIL=1 DEV_BRAIN_CURATOR_MAX_ATTEMPTS=2 >/dev/null
  assert_eq 1 "$(count_files "$base/queue/pending")" "pending after first failure"
  assert_eq 0 "$(count_files "$base/queue/running")" "running after first failure"

  run_curator "$base" FAKE_FAIL=1 DEV_BRAIN_CURATOR_MAX_ATTEMPTS=2 >/dev/null
  assert_eq 0 "$(count_files "$base/queue/pending")" "pending after second failure"
  assert_eq 1 "$(count_files "$base/queue/failed")" "failed after second failure"
  last_run "$base" | grep -q 'failed=1'
}

session_paths_are_never_committed() {
  local base
  base="$(setup_case session)"
  enqueue "$base/queue" "touch task"

  run_curator "$base" FAKE_TOUCH_TASK=1 >/dev/null

  git -C "$base/vault" show --name-only --format= HEAD | grep -q 'tasks/' && { echo "session-owned path was committed" >&2; exit 1; }
  grep -q 'owned by a work session' "$base"/queue/logs/run-*.log
}

live_lock_blocks_second_run() {
  local base status
  base="$(setup_case locked)"
  enqueue "$base/queue" "waiting"
  sleep 60 &
  SLEEPER_PID=$!
  disown "$SLEEPER_PID"
  mkdir -p "$base/queue/.worker.lock"
  echo "$SLEEPER_PID" > "$base/queue/.worker.lock/pid"

  set +e
  run_curator "$base" >/dev/null 2>&1
  status=$?
  set -e

  assert_eq 75 "$status" "exit status while another run holds the lock"
  assert_eq 1 "$(count_files "$base/queue/pending")" "pending while locked"
  kill "$SLEEPER_PID" 2>/dev/null || true
}

stale_lock_is_recovered() {
  local base
  base="$(setup_case stale)"
  enqueue "$base/queue" "after crash"
  mkdir -p "$base/queue/.worker.lock" "$base/queue/running"
  echo 999999 > "$base/queue/.worker.lock/pid"
  touch -t 202601010000 "$base/queue/.worker.lock"

  run_curator "$base" >/dev/null

  assert_eq 1 "$(count_files "$base/queue/done")" "done after stale lock recovery"
  [[ ! -d "$base/queue/.worker.lock" ]]
}

concurrent_hub_appends_merge_without_conflict() {
  local base other
  base="$(setup_case hub)"
  other="$base/other"
  git clone -q "$base/remote.git" "$other"
  sed -i '' 's/^## 当前状态$/## 当前状态\n\n- 来自另一台机器/' "$other/projects/p1/_hub.md"
  git_q -C "$other" commit -q -am "other machine"
  git -C "$other" push -q

  enqueue "$base/queue" "hub"
  run_curator "$base" FAKE_HUB_LINE="来自本机 curator" >/dev/null

  last_run "$base" | grep -q 'sync=ok: pushed'
  git -C "$base/remote.git" show master:projects/p1/_hub.md > "$TMPDIR/hub.md"
  grep -q '来自另一台机器' "$TMPDIR/hub.md"
  grep -q '来自本机 curator' "$TMPDIR/hub.md"
}

commits_only_reported_paths_and_pushes_despite_session_edits
defers_sync_when_remote_moved_and_tree_dirty
autosaves_idle_session_dirs_only
pushes_when_clean
duplicate_content_skips_codex
failure_requeues_then_gives_up
session_paths_are_never_committed
live_lock_blocks_second_run
stale_lock_is_recovered
concurrent_hub_appends_merge_without_conflict

echo "dev-brain-curator tests passed"
