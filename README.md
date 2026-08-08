# herdr-limit-relay

> Translation of the canonical [README.zh-TW.md](README.zh-TW.md); may lag
> behind it.

Automatic takeover when Claude Code hits the 5-hour usage limit. Written
for **herdr 0.8.0**.

Two options sharing one detection layer:

| | What it does | Good for |
|---|---|---|
| **Option A — `resumer.sh`** | Waits for the limit to lift, then wakes the original Claude session | Single provider; you just want "the work was done when I woke up" |
| **Option B — `relay.sh`** | Opens a git worktree during the wait and lets Codex work a safe task list; Claude reviews on return | You have a Codex/Grok subscription and don't want to waste those 5 hours |

Both can be installed at once. Option B calls into Option A's resume
logic internally.

---

## Architecture

```text
Claude Code (in herdr pane)
   │
   │ StopFailure hook (matcher: rate_limit)   ← official structured event, not screen scraping
   ▼
hooks/limit-watch.sh
   ├─ append → ~/.herdr-limit/ledger.jsonl   { pane, session_id, cwd }
   ├─ herdr pane report-metadata             ← sidebar shows "rate limited"
   └─ herdr notification show

bin/resumer.sh (daemon, consumes no tokens)
   ├─ every 5 min, a haiku probe tests whether quota is back
   ├─ pane still alive → herdr agent prompt --wait
   └─ pane gone        → herdr workspace create + agent start --kind claude -- --resume <sid>

bin/relay.sh (daemon, Option B)
   └─ on limit hit → herdr worktree create + agent start --kind codex
```

**Why a hook instead of scanning the screen**: `StopFailure`'s matcher
supports `rate_limit` directly — an official structured event carrying
`session_id` and `cwd`. The hundreds of lines community tmux tools spend
on ANSI stripping + banner regexes + timezone parsing are simply not
needed here.

**Why we don't parse the reset time**: the `StopFailure` input schema is
still undocumented
([anthropics/claude-code#35620](https://github.com/anthropics/claude-code/issues/35620))
and a reset time is not guaranteed. So we poll with a haiku probe
instead — timezones, DST, and banner format changes, the three most
fragile parts, disappear entirely. The cost is resuming up to 5 minutes
late.

---

## Install

Prerequisites: `herdr` ≥ 0.8.0, `jq`, Claude Code, `~/.claude` exists.
Currently tested on macOS only (launchd, osascript); Linux guidance is
best-effort.

```bash
# 1. Install herdr's official claude integration first (if you haven't)
herdr integration install claude
herdr integration status          # Claude Code integration version >= 6

# 2. Install this
cd herdr-limit-relay
./install.sh
```

`install.sh` will:

- copy the hook to `~/.claude/hooks/limit-watch.sh`
- use jq to **merge** (not overwrite) the `StopFailure` entry into
  `~/.claude/settings.json`, with a backup first
- create `~/.herdr-limit/`
- print the daemon start commands

**Note: the hook is a copy.** `install.sh` **copies**
`hooks/limit-watch.sh` into `~/.claude/hooks/`, so later edits to the
hook in this repo (or a `git pull`) do not affect the installed one —
re-run `./install.sh` after changing it.

Verify after installing:

```bash
./bin/selftest.sh --post-install
./bin/test-hook.sh              # offline hook parsing test; no herdr, no tokens
jq '.hooks.StopFailure' ~/.claude/settings.json
claude   # open inside a herdr pane, then /hooks should list StopFailure
```

To remove: `./uninstall.sh` deletes only this tool's StopFailure entry
(herdr's own hooks are untouched) and the copied hook file; daemons,
launchd agents, and `~/.herdr-limit/` are yours to clean up — it prints
reminders.

---

## Option A: local resume

```bash
# Run in the foreground (test it this way first)
./bin/resumer.sh

# Long-running (macOS): launchd - starts at login, restarts if it dies
sed -e "s|__REPO__|$PWD|g" -e "s|__HOME__|$HOME|g" \
    templates/resumer.launchd.plist \
    > ~/Library/LaunchAgents/com.herdr-limit.resumer.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.herdr-limit.resumer.plist

# Or: run it manually in a herdr pane
herdr workspace create --label ops --no-focus
# then run ./bin/resumer.sh in that pane
```

After updating `bin/resumer.sh`, restart the daemon (launchd runs the
code as of process start):
`launchctl kickstart -k "gui/$(id -u)/com.herdr-limit.resumer"`

Tunable environment variables:

| Variable | Default | Notes |
|---|---|---|
| `RESUME_POLL_SECONDS` | `300` | Probe interval. Don't set too low; each probe is a request |
| `RESUME_PROBE_MODEL` | `haiku` | Probe model — use the cheapest |
| `RESUME_MESSAGE` | see script | Prompt sent on resume |
| `RESUME_MAX_ATTEMPTS` | `5` | Retry cap per session, so a loop can't burn quota |
| `RESUME_TIMEOUT_MS` | `1800000` | Cap on waiting for the agent to finish (30 min) |
| `RESUME_PROBE_BROKEN_ALERT` | `3` | Notify after this many consecutive probe failures for NON-limit reasons (network down, auth expired, broken CLI) |

**Keep the resume prompt conservative.** The default is `Continue where
you left off. If the task is already complete, reply DONE and stop.` It
gives the agent an explicit exit; otherwise it may freewheel in the new
window and burn the quota again.

---

## Option B: cross-provider takeover

```bash
export RELAY_AGENT_KIND=codex        # or grok / gemini / opencode
./bin/relay.sh
```

When the limit trips, `relay.sh` will:

1. create a git worktree from the original repo (branch
   `nightshift/YYYYmmdd-HHMM`)
2. run `herdr agent start --kind codex` in the new workspace
3. feed it ONLY the items tagged `[relay-safe]` in `TASKS.md`
4. commit after each finished item and record it in `RELAY-LOG.md`
5. when Claude returns, `resumer.sh` has Claude review that branch first

### Why a worktree

Two agents from different providers editing the same working tree =
mutual-overwrite disaster. `herdr worktree create` is a native command;
isolation in one line.

### Handoff protocol

Conversation history **cannot** cross providers. Claude's transcripts
live in `~/.claude/projects/*.jsonl`; Codex can't read them. The only
things that transfer are what lands on disk:

| Carrier | Notes |
|---|---|
| `TASKS.md` | Most important. Both sides must update it after every step |
| `CLAUDE.md` / `AGENTS.md` | Project conventions. Symlink so both read the same file |
| git commits + diff | The most honest source of state |
| `RELAY-LOG.md` | Written by the stand-in for the original agent |

`templates/` holds two templates: copy `TASKS.md` straight into your
project root; **append** `RELAY-CONTRACT.md` (the stand-in agent
contract) to your project's existing `AGENTS.md` — do not replace that
file. The contract applies only to the stand-in situation and would be
wrong as everyday development rules.

### What earns `[relay-safe]`

Only **mechanical, verifiable, cheap-to-fail** work: adding tests,
docstrings, lint fixes, README updates, obvious TODO comments,
dependency bumps.

**Never tag**: architecture decisions, cross-file refactors,
schema/migration changes, anything touching CI/deploy config. Those
wait for Claude.

---

## Safety design (every line is deliberate)

| Risk | How it's handled |
|---|---|
| Keys sent to the wrong program | `herdr agent prompt`, never `pane send-keys`. Docs: agent input resolves the current agent and refuses if that agent no longer controls the pane |
| Recycled pane id delivers to a stranger | Same as above — `agent prompt` blocks it natively; `agent wait` also pins the resolved pane occupant |
| Accidentally selecting "Upgrade your plan" in the limit menu | Menus are never touched. Only `agent prompt` text |
| Seizing state authority from herdr's integration | `pane report-metadata` (display-only), not `report-agent` |
| Infinite retries burning the quota | `RESUME_MAX_ATTEMPTS`; give up and notify past the cap |
| Unattended agent changing random things | **No** `--dangerously-skip-permissions`. Option B isolates via worktree instead of skipping permissions |
| Scripts break and you don't know | `healthcheck.sh` + heartbeat files, below |

---

## Dead man's switch (install this, really)

herdr is 0.8.0, protocol v15, still bumping. Your scripts will break on
some upgrade, and you'll find out **the next morning when nothing got
done overnight**.

```bash
# macOS: use launchd. The first crontab write waits for TCC approval, and
# the dialog only appears on the local screen - from an SSH session it
# simply hangs forever.
sed -e "s|__REPO__|$PWD|g" -e "s|__HOME__|$HOME|g" \
    templates/healthcheck.launchd.plist \
    > ~/Library/LaunchAgents/com.herdr-limit.healthcheck.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.herdr-limit.healthcheck.plist

# Linux: crontab -e
# 0 * * * * /path/to/herdr-limit-relay/bin/healthcheck.sh
```

Note: launchd agents live in the `gui` domain and stop when the console
user logs out; keep unattended machines logged in (or convert to a
LaunchDaemon).

`healthcheck.sh` checks the mtime of `~/.herdr-limit/heartbeat` and
fires a desktop notification when it's older than 3× the poll interval.

Also strongly recommended:

```bash
herdr channel set stable      # don't run preview
# before any upgrade: ./bin/selftest.sh
```

---

## Known limits / things to verify yourself

1. **The JSON field names of `herdr agent get`** are not individually
   verified. The scripts deliberately check exit codes rather than
   parsing fields — `agent get` succeeding means the pane is alive;
   `agent prompt` failing falls back to the respawn path. That way
   upgrades break less. For the exact schema:
   `herdr api schema --json | jq`.

2. **`agent prompt --wait` stall behavior**: when prompted from a
   non-working state, herdr requires an observed lifecycle change
   within 5s, else it returns `agent_prompt_stalled`. The scripts
   handle that error and retry.

3. **Older command syntax differs.** Many herdr tutorials online use
   `herdr wait output 1-3 --match ...` — that's the pre-0.6 form. In
   0.8.0 it's `herdr pane wait-output w1:p1 --regex ...` with `w1:p1`
   pane ids. Trust `herdr --help` and the official socket API docs.

4. **Each probe consumes one request.** `RESUME_POLL_SECONDS=300` means
   12 haiku requests per hour — negligible, but don't set it to 30
   seconds.

5. **Weekly limits are not handled.** On a weekly limit the probe fails
   for days; `RESUME_MAX_ATTEMPTS` never triggers (nothing is ever
   sent). The script keeps polling — deliberately — but you will get
   healthcheck notifications.

6. **herdr is AGPL-3.0.** Fine for personal use; read the obligations
   before shipping it in a product or hosted service. This repo only
   shells out to the `herdr` binary and links none of its code, so it
   carries no AGPL obligations — the repo itself is MIT licensed (see
   `LICENSE`).
