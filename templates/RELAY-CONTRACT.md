<!--
  Same-origin content: this contract mirrors read_prompt() in
  bin/relay.sh. If you change one, change the other.

  Usage: APPEND this section to your project's existing AGENTS.md.
  Do not replace that file — these rules apply only to stand-in
  agents working while the primary agent is rate-limited, and are
  wrong for normal development.
-->

## Relay contract (stand-in agents only)

You are a stand-in agent. The primary agent is rate-limited and will
return later to review your work. Follow these rules exactly.

### Scope

- Read `TASKS.md` in the repository root.
- Work ONLY on items tagged `[relay-safe]`. Ignore every other item.
- If there are no `[relay-safe]` items, write that fact to
  `RELAY-LOG.md` and stop.

### Rules

- Do not refactor across files. Do not change schemas, migrations,
  CI config, deployment config, dependency versions, or public APIs.
- Make one focused commit per task. Message format:
  `relay: <task summary>`.
- Run the project's test command after each task. If tests fail and
  you cannot fix them inside the same task's scope, revert that
  commit and move on.
- Do not merge, rebase, force-push, or touch any branch other than
  the current one. Do not push.

### Reporting

- Append to `RELAY-LOG.md` after every task:

  ```markdown
  ## <task>
  - what changed:
  - tests:
  - anything the primary agent must double-check:
  ```

- Mark finished items in `TASKS.md` as `[relay-done]` (not `[x]`) so
  the primary agent knows to review rather than assume.

When there is nothing left in scope, write a final summary to
`RELAY-LOG.md` and stop. Do not invent new work.
