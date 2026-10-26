#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/_system/bin/dev-brain-handoff"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

handoff=$'dev-brain handoff\nproject: knowledge\nkind: research\nsource: test-repo@abc123:path/to/file\nkeywords: test curator queue\nsummary: test handoff\n'

count_files() {
  find "$1" -type f -name '*.txt' 2>/dev/null | wc -l | tr -d ' '
}

assert_eq() {
  if [[ "$1" != "$2" ]]; then
    echo "expected $3 to be '$1', got '$2'" >&2
    exit 1
  fi
}

queue_invalid_input() {
  local queue="$TMPDIR/q-invalid"
  set +e
  printf 'not a handoff\n' | "$SCRIPT" --queue-dir "$queue" >"$TMPDIR/invalid.out" 2>"$TMPDIR/invalid.err"
  local status=$?
  set -e

  assert_eq 2 "$status" "invalid input exit status"
  assert_eq 1 "$(count_files "$queue/failed")" "invalid failed file count"
  grep -q 'not a dev-brain handoff' "$TMPDIR/invalid.err"
}

enqueue_writes_pending_only() {
  local queue="$TMPDIR/q-enqueue"
  printf '%s' "$handoff" | "$SCRIPT" --queue-dir "$queue" >"$TMPDIR/enqueue.out"

  grep -q '^queued:' "$TMPDIR/enqueue.out"
  assert_eq 1 "$(count_files "$queue/pending")" "pending file count after enqueue"
  assert_eq 0 "$(count_files "$queue/running")" "running file count after enqueue"
  cmp -s <(printf '%s' "$handoff") "$(find "$queue/pending" -name '*.txt')"

  # --enqueue-only is still accepted for older callers.
  printf '%s' "$handoff" | "$SCRIPT" --queue-dir "$queue" --enqueue-only >/dev/null
  assert_eq 2 "$(count_files "$queue/pending")" "pending file count after --enqueue-only"
}

status_reports_counts_and_lock() {
  local queue="$TMPDIR/q-status"
  printf '%s' "$handoff" | "$SCRIPT" --queue-dir "$queue" >/dev/null
  "$SCRIPT" --queue-dir "$queue" --status >"$TMPDIR/status.out"
  grep -q '^pending: 1$' "$TMPDIR/status.out"
  grep -q '^lock: absent$' "$TMPDIR/status.out"
}

recover_stale_lock_requeues_running_job() {
  local queue="$TMPDIR/q-recover"
  mkdir -p "$queue"/{pending,running,done,failed,logs}
  printf '%s' "$handoff" > "$queue/running/stuck.txt"
  mkdir "$queue/.worker.lock"

  "$SCRIPT" --queue-dir "$queue" --recover-stale --stale-minutes 0 >"$TMPDIR/recover.out"

  assert_eq 1 "$(count_files "$queue/pending")" "pending file count after stale recovery"
  assert_eq 0 "$(count_files "$queue/running")" "running file count after stale recovery"
  [[ ! -d "$queue/.worker.lock" ]]
  grep -q '^recovered stale worker lock:' "$TMPDIR/recover.out"
}

recover_orphaned_running_job_without_lock() {
  local queue="$TMPDIR/q-recover-orphan"
  mkdir -p "$queue"/{pending,running,done,failed,logs}
  printf '%s' "$handoff" > "$queue/running/orphan.txt"

  "$SCRIPT" --queue-dir "$queue" --recover-stale --stale-minutes 0 >"$TMPDIR/recover-orphan.out"

  assert_eq 1 "$(count_files "$queue/pending")" "pending file count after orphan recovery"
  assert_eq 0 "$(count_files "$queue/running")" "running file count after orphan recovery"
  grep -q '^recovered orphaned running jobs$' "$TMPDIR/recover-orphan.out"
}

recover_refuses_live_lock() {
  local queue="$TMPDIR/q-recover-live"
  mkdir -p "$queue"/{pending,running,done,failed,logs} "$queue/.worker.lock"
  echo "$$" > "$queue/.worker.lock/pid"
  printf '%s' "$handoff" > "$queue/running/busy.txt"

  set +e
  "$SCRIPT" --queue-dir "$queue" --recover-stale --stale-minutes 0 >"$TMPDIR/recover-live.out"
  local status=$?
  set -e

  assert_eq 1 "$status" "recover exit status with a live lock"
  assert_eq 1 "$(count_files "$queue/running")" "running file count with a live lock"
  grep -q '^curator still running: pid' "$TMPDIR/recover-live.out"
}

queue_invalid_input
enqueue_writes_pending_only
status_reports_counts_and_lock
recover_stale_lock_requeues_running_job
recover_orphaned_running_job_without_lock
recover_refuses_live_lock

echo "dev-brain-handoff tests passed"
