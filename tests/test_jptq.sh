#!/usr/bin/env bash
set -euo pipefail

# Integration tests for jptq
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JPTQ="${SCRIPT_DIR}/../jptq"
TMPDIR_BASE=$(mktemp -d)
PASS=0
FAIL=0
TESTS=()

cleanup() {
    rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT

# ──────────────────────────────────────────────
# Test helpers
# ──────────────────────────────────────────────

new_db() {
    local db="${TMPDIR_BASE}/test_$(date +%s%N).db3"
    "$JPTQ" init "$db" > /dev/null
    echo "$db"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo "  PASS: $desc"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $desc"
        echo "    expected: '$expected'"
        echo "    actual:   '$actual'"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS=$((PASS + 1))
        echo "  PASS: $desc"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $desc"
        echo "    expected to contain: '$needle'"
        echo "    actual: '$haystack'"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        PASS=$((PASS + 1))
        echo "  PASS: $desc"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $desc"
        echo "    expected NOT to contain: '$needle'"
        echo "    actual: '$haystack'"
    fi
}

db_state() {
    local db="$1" task_id="$2"
    "$JPTQ" list "$db" 2>/dev/null | grep "$task_id" | awk '{print $2}' || true
}

SQLITE3="${JPTQ_SQLITE3:-sqlite3}"
db_field() {
    local db="$1" field="$2" task_id="$3"
    "$SQLITE3" "$db" "SELECT ${field} FROM tasks WHERE id = '${task_id}';"
}

# ──────────────────────────────────────────────
# Tests
# ──────────────────────────────────────────────

test_init() {
    echo "TEST: init"
    local db="${TMPDIR_BASE}/init_test.db3"
    local out
    out=$("$JPTQ" init "$db")
    assert_contains "init prints confirmation" "Initialized" "$out"

    # Check table exists
    local tables
    tables=$("$SQLITE3" "$db" "SELECT name FROM sqlite_master WHERE type='table' AND name='tasks';")
    assert_eq "tasks table created" "tasks" "$tables"
}

test_add_one_time_task() {
    echo "TEST: add one-time task"
    local db
    db=$(new_db)

    local out
    out=$("$JPTQ" task "$db" t1 echo hello world)
    assert_contains "task add confirmation" "Added task: t1" "$out"

    local state
    state=$(db_state "$db" "t1")
    assert_eq "task state is queued" "queued" "$state"

    local cmd
    cmd=$(db_field "$db" "command" "t1")
    assert_eq "command stored correctly" "echo hello world" "$cmd"
}

test_add_task_with_at() {
    echo "TEST: add task with --at"
    local db
    db=$(new_db)

    "$JPTQ" task "$db" --at "2099-01-01 00:00:00" t_sched echo future > /dev/null
    local sched
    sched=$(db_field "$db" "scheduled_at" "t_sched")
    assert_eq "scheduled_at set correctly" "2099-01-01 00:00:00" "$sched"
}

test_add_recurring_task() {
    echo "TEST: add recurring task"
    local db
    db=$(new_db)

    local out
    out=$("$JPTQ" interval "$db" 5 r1 echo recurring)
    assert_contains "interval add confirmation" "Added recurring task: r1" "$out"

    local interval
    interval=$(db_field "$db" "interval" "r1")
    assert_eq "interval stored" "5" "$interval"
}

test_duplicate_task_error() {
    echo "TEST: duplicate task ID error"
    local db
    db=$(new_db)

    "$JPTQ" task "$db" dup1 echo first > /dev/null
    local out
    out=$("$JPTQ" task "$db" dup1 echo second 2>&1) || true
    assert_contains "duplicate error message" "already exists" "$out"
}

test_list() {
    echo "TEST: list"
    local db
    db=$(new_db)

    "$JPTQ" task "$db" list1 echo one > /dev/null
    "$JPTQ" task "$db" list2 echo two > /dev/null

    local out
    out=$("$JPTQ" list "$db")
    assert_contains "list shows task 1" "list1" "$out"
    assert_contains "list shows task 2" "list2" "$out"
    assert_contains "list shows header" "ID" "$out"
}

test_list_empty() {
    echo "TEST: list empty"
    local db
    db=$(new_db)
    local out
    out=$("$JPTQ" list "$db")
    assert_contains "empty list message" "No tasks found" "$out"
}

test_delete() {
    echo "TEST: delete"
    local db
    db=$(new_db)

    "$JPTQ" task "$db" del1 echo bye > /dev/null
    local out
    out=$("$JPTQ" delete "$db" del1)
    assert_contains "delete confirmation" "Deleted task: del1" "$out"

    local list_out
    list_out=$("$JPTQ" list "$db")
    assert_not_contains "task removed from list" "del1" "$list_out"
}

test_delete_nonexistent() {
    echo "TEST: delete nonexistent"
    local db
    db=$(new_db)
    local out
    out=$("$JPTQ" delete "$db" nope 2>&1) || true
    assert_contains "delete not found error" "not found" "$out"
}

test_pause_and_restore() {
    echo "TEST: pause and restore"
    local db
    db=$(new_db)

    "$JPTQ" task "$db" pr1 echo test > /dev/null

    # Pause
    local out
    out=$("$JPTQ" pause "$db" pr1)
    assert_contains "pause confirmation" "Paused task: pr1" "$out"
    local state
    state=$(db_state "$db" "pr1")
    assert_eq "state is paused" "paused" "$state"

    # Restore
    out=$("$JPTQ" restore "$db" pr1)
    assert_contains "restore confirmation" "Restored task: pr1" "$out"
    state=$(db_state "$db" "pr1")
    assert_eq "state is queued after restore" "queued" "$state"

    # Check retry_count reset
    local retry
    retry=$(db_field "$db" "retry_count" "pr1")
    assert_eq "retry_count reset to 0" "0" "$retry"
}

test_pause_wrong_state() {
    echo "TEST: pause wrong state (paused task)"
    local db
    db=$(new_db)
    "$JPTQ" task "$db" pw1 echo test > /dev/null
    "$JPTQ" pause "$db" pw1 > /dev/null

    # Try to pause again (already paused)
    local out
    out=$("$JPTQ" pause "$db" pw1 2>&1) || true
    assert_contains "pause wrong state error" "not in queued/failed" "$out"
}

test_consume_one_time() {
    echo "TEST: consume one-time task"
    local db
    db=$(new_db)

    local outfile="${TMPDIR_BASE}/out_onetime.txt"
    "$JPTQ" task "$db" c1 "echo consumed > ${outfile}" > /dev/null

    # Run consumer in background, let it process, then kill
    "$JPTQ" consume "$db" 0.01 &
    local consumer_pid=$!
    sleep 2
    kill "$consumer_pid" 2>/dev/null || true
    wait "$consumer_pid" 2>/dev/null || true

    # Check task was executed
    if [[ -f "$outfile" ]]; then
        local content
        content=$(cat "$outfile")
        assert_eq "task output correct" "consumed" "$content"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: output file not created"
    fi

    # Check state
    local state
    state=$(db_state "$db" "c1")
    assert_eq "one-time task completed" "completed" "$state"
}

test_consume_recurring() {
    echo "TEST: consume recurring task"
    local db
    db=$(new_db)

    local outfile="${TMPDIR_BASE}/out_recurring.txt"
    "$JPTQ" interval "$db" 1 rec1 "echo tick >> ${outfile}" > /dev/null

    "$JPTQ" consume "$db" 0.01 &
    local consumer_pid=$!
    sleep 2
    kill "$consumer_pid" 2>/dev/null || true
    wait "$consumer_pid" 2>/dev/null || true

    # Recurring task should be queued again (not completed)
    local state
    state=$(db_state "$db" "rec1")
    assert_eq "recurring task re-queued" "queued" "$state"

    # Output file should exist with at least one tick
    if [[ -f "$outfile" ]]; then
        assert_contains "recurring task executed" "tick" "$(cat "$outfile")"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: recurring output file not created"
    fi
}

test_retry_and_backoff() {
    echo "TEST: retry and backoff"
    local db
    db=$(new_db)

    "$JPTQ" task "$db" fail1 "exit 1" > /dev/null

    # Run consumer briefly to trigger first retry
    "$JPTQ" consume "$db" 0.01 &
    local consumer_pid=$!
    sleep 2
    kill "$consumer_pid" 2>/dev/null || true
    wait "$consumer_pid" 2>/dev/null || true

    # Check retry count incremented
    local retry
    retry=$(db_field "$db" "retry_count" "fail1")
    assert_eq "retry count incremented to 1" "1" "$retry"

    # Check state is queued (with backoff)
    local state
    state=$(db_state "$db" "fail1")
    assert_eq "task re-queued after failure" "queued" "$state"
}

test_max_retries_fail() {
    echo "TEST: max retries → failed"
    local db
    db=$(new_db)

    "$JPTQ" task "$db" maxfail "exit 1" > /dev/null

    # Set retry_count to 9 so next failure pushes to 10 → failed
    "$SQLITE3" "$db" "UPDATE tasks SET retry_count = 9 WHERE id = 'maxfail';"

    "$JPTQ" consume "$db" 0.01 &
    local consumer_pid=$!
    sleep 2
    kill "$consumer_pid" 2>/dev/null || true
    wait "$consumer_pid" 2>/dev/null || true

    local state
    state=$(db_state "$db" "maxfail")
    assert_eq "task failed after max retries" "failed" "$state"

    local retry
    retry=$(db_field "$db" "retry_count" "maxfail")
    assert_eq "retry count is 10" "10" "$retry"
}

test_pause_failed_task() {
    echo "TEST: pause failed task"
    local db
    db=$(new_db)

    "$JPTQ" task "$db" pfail "exit 1" > /dev/null
    "$SQLITE3" "$db" "UPDATE tasks SET state = 'failed', retry_count = 10 WHERE id = 'pfail';"

    local out
    out=$("$JPTQ" pause "$db" pfail)
    assert_contains "pause failed task works" "Paused" "$out"

    local state
    state=$(db_state "$db" "pfail")
    assert_eq "failed task now paused" "paused" "$state"
}

test_stale_recovery() {
    echo "TEST: stale task recovery"
    local db
    db=$(new_db)

    "$JPTQ" task "$db" stale1 "echo recovered" > /dev/null

    # Simulate a dead worker: set state to running with a non-existent PID
    "$SQLITE3" "$db" "UPDATE tasks SET state = 'running', worker_pid = 999999 WHERE id = 'stale1';"

    local state_before
    state_before=$(db_state "$db" "stale1")
    assert_eq "task is running (simulated)" "running" "$state_before"

    # Run consumer briefly — it should recover the stale task
    local outfile="${TMPDIR_BASE}/out_stale.txt"
    "$SQLITE3" "$db" "UPDATE tasks SET command = 'echo recovered > ${outfile}' WHERE id = 'stale1';"

    "$JPTQ" consume "$db" 0.01 &
    local consumer_pid=$!
    sleep 2
    kill "$consumer_pid" 2>/dev/null || true
    wait "$consumer_pid" 2>/dev/null || true

    local state_after
    state_after=$(db_state "$db" "stale1")
    assert_eq "stale task completed after recovery" "completed" "$state_after"
}

test_sql_injection_prevention() {
    echo "TEST: SQL injection prevention"
    local db
    db=$(new_db)

    # Task ID with single quotes
    local out
    out=$("$JPTQ" task "$db" "it's-a-task" "echo 'hello world'" 2>&1) || true
    assert_contains "task with quotes added" "Added task" "$out"

    # Verify it's in the list
    local list_out
    list_out=$("$JPTQ" list "$db")
    assert_contains "quoted task in list" "it's-a-task" "$list_out"
}

test_backoff_values() {
    echo "TEST: backoff computation"
    local db
    db=$(new_db)

    # Source the compute_backoff function
    source "$JPTQ"  2>/dev/null || true

    local b1 b2 b3 b4
    b1=$(compute_backoff 1)
    b2=$(compute_backoff 2)
    b3=$(compute_backoff 3)
    b4=$(compute_backoff 4)

    assert_eq "backoff retry 1 = 5 min" "5" "$b1"
    assert_eq "backoff retry 2 = 10 min" "10" "$b2"
    assert_eq "backoff retry 3 = 15 min" "15" "$b3"
    assert_eq "backoff retry 4 = 15 min (capped)" "15" "$b4"
}

test_scheduled_at_future() {
    echo "TEST: future scheduled task not consumed"
    local db
    db=$(new_db)

    "$JPTQ" task "$db" --at "2099-12-31 23:59:59" future1 echo nope > /dev/null

    "$JPTQ" consume "$db" 0.01 &
    local consumer_pid=$!
    sleep 2
    kill "$consumer_pid" 2>/dev/null || true
    wait "$consumer_pid" 2>/dev/null || true

    local state
    state=$(db_state "$db" "future1")
    assert_eq "future task not consumed" "queued" "$state"
}

# ──────────────────────────────────────────────
# Run all tests
# ──────────────────────────────────────────────

echo "=== jptq integration tests ==="
echo ""

test_init
test_add_one_time_task
test_add_task_with_at
test_add_recurring_task
test_duplicate_task_error
test_list
test_list_empty
test_delete
test_delete_nonexistent
test_pause_and_restore
test_pause_wrong_state
test_consume_one_time
test_consume_recurring
test_retry_and_backoff
test_max_retries_fail
test_pause_failed_task
test_stale_recovery
test_sql_injection_prevention
test_backoff_values
test_scheduled_at_future

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
