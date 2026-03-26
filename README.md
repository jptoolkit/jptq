# jptq — Bash Task Queue Runner

[![Build Status](https://github.com/jptoolkit/jptq/workflows/Build/badge.svg)](https://github.com/jptoolkit/jptq/actions)

A lightweight, persistent task queue for the Linux command line. `jptq` manages shell tasks using a SQLite database, supporting one-time and recurring execution, automatic retries with backoff, scheduled runs, and graceful recovery from crashes.

## Features

- **Persistent queue** — task state is stored in SQLite; survives restarts and crashes
- **One-time & recurring tasks** — run a command once or repeat it on a fixed interval
- **Scheduled execution** — schedule tasks for a specific date and time
- **Automatic retries** — failed tasks are retried up to 10 times with progressive backoff (5, 10, 15 min)
- **State machine** — strict state transitions prevent duplicate execution (`queued → running → completed/failed/paused`)
- **Stale task recovery** — detects dead worker processes and requeues their tasks
- **Pause & restore** — suspend and resume individual tasks by ID
- **SQL injection prevention** — all user inputs are properly escaped
- **Zero dependencies** — requires only Bash and sqlite3 (no package managers, no build step)

## Requirements

- **Bash** 4.0 or later
- **sqlite3** CLI tool (usually pre-installed on most Linux distributions)

## Installation

```bash
git clone git@github.com:jptoolkit/jptq.git jptq
cd jptq
chmod +x jptq
```

### Local installation (recommended)

Installs into `~/.local/` for the current user only. Uses a symlink, so pulling updates from git takes effect immediately.

```bash
mkdir -p ~/.local/opt ~/.local/bin
cp -r . ~/.local/opt/jptq
ln -s ~/.local/opt/jptq/jptq ~/.local/bin/jptq
```

Make sure `~/.local/bin` is in your `PATH` (add to `~/.bashrc` or `~/.profile` if not):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

To update later:

```bash
cd ~/.local/opt/jptq && git pull
```

### Global installation

Installs system-wide for all users (requires root):

```bash
sudo ln -s "$(pwd)/jptq" /usr/local/bin/jptq
```

Or copy it directly:

```bash
sudo cp jptq /usr/local/bin/jptq
```

## Quick Start

```bash
# 1. Initialize a queue database
./jptq init myqueue.db3

# 2. Add a task
./jptq task myqueue.db3 backup-logs "tar czf /tmp/logs.tar.gz /var/log/myapp"

# 3. Add a recurring task (every 30 minutes)
./jptq interval myqueue.db3 30 health-check "curl -sf http://localhost:8080/health"

# 4. View all tasks
./jptq list myqueue.db3

# 5. Start the consumer
./jptq consume myqueue.db3
```

## Usage

### Initialize a queue

```bash
jptq init <queue_file>
```

Creates a new SQLite database with the required schema.

### Add a one-time task

```bash
jptq task <queue_file> <task_id> <command...>
```

The task is queued for immediate execution. Task IDs must be unique (e.g., `issue-987`, `deploy-v2`).

### Schedule a task

```bash
jptq task <queue_file> --at "2025-06-15 14:30:00" <task_id> <command...>
```

The task will not run before the specified time.

### Add a recurring task

```bash
jptq interval <queue_file> <interval_minutes> <task_id> <command...>
```

After each successful completion, the task is automatically requeued with the given interval.

### Delete a task

```bash
jptq delete <queue_file> <task_id>
```

### Pause a task

```bash
jptq pause <queue_file> <task_id>
```

Pauses a task in `queued` or `failed` state.

### Restore a paused task

```bash
jptq restore <queue_file> <task_id>
```

Returns a paused task to the queue and resets its retry count.

### List all tasks

```bash
jptq list <queue_file>
```

Displays a formatted table with all tasks and their current state.

### Start the consumer

```bash
jptq consume <queue_file> [poll_interval_minutes]
```

Starts processing queued tasks. The consumer polls for new tasks at the given interval (default: 1 minute). Send `SIGTERM` or `SIGINT` (Ctrl+C) to stop gracefully — the current task will finish before the consumer exits.

## Task States

```
                 pause
    ┌───────────────────────────────┐
    │                               ▼
┌───┴──────┐                  ┌──────────┐
│  queued   │◄─── restore ───│  paused  │
└────┬─────┘                  └──────────┘
     │                               ▲
     ▼                               │ pause
┌──────────┐                         │
│ running  │────┐                    │
└──────────┘    │                    │
     │          ▼                    │
     │    ┌──────────┐               │
     │    │  failed  │───────────────┘
     │    └────┬─────┘
     │         │ retry (up to 10×)
     │         └──────────────► queued
     ▼
┌───────────┐
│ completed │
└───────────┘
```

- **queued** — waiting to be picked up by the consumer
- **running** — currently being executed by a worker
- **completed** — finished successfully (recurring tasks are requeued automatically)
- **failed** — exited with non-zero code; retried automatically or paused manually
- **paused** — suspended; use `restore` to requeue

## Retry Logic

When a task fails (non-zero exit code), it is automatically retried with increasing delays:

| Attempt | Delay  |
|---------|--------|
| 1       | 5 min  |
| 2       | 10 min |
| 3+      | 15 min |

After 10 failed attempts, the task is marked as permanently `failed` and is not retried.

## Environment Variables

| Variable       | Default   | Description                  |
|----------------|-----------|------------------------------|
| `JPTQ_SQLITE3` | `sqlite3` | Path to the sqlite3 binary   |

## Running Tests

```bash
./tests/test_jptq.sh
```

The test suite includes 18 integration tests covering task creation, scheduling, consumption, retry logic, stale recovery, and SQL injection prevention.

## Database Schema

Each task in the SQLite database has the following columns:

| Column         | Type    | Description                                      |
|----------------|---------|--------------------------------------------------|
| `id`           | TEXT    | Unique task identifier (primary key)             |
| `state`        | TEXT    | Current state (`queued`, `running`, `completed`, `failed`, `paused`) |
| `created_at`   | TEXT    | Timestamp when the task was added                |
| `scheduled_at` | TEXT    | Earliest time the task may run                   |
| `started_at`   | TEXT    | Timestamp when execution began                   |
| `retry_count`  | INTEGER | Number of failed attempts so far                 |
| `interval`     | INTEGER | Recurrence interval in minutes (NULL for one-time tasks) |
| `command`      | TEXT    | Shell command to execute                         |
| `worker_pid`   | INTEGER | PID of the worker currently executing the task   |
