# TASKS

Shared between every agent working this repo, whatever provider it is.
This file is the handoff protocol. Conversation history does not survive a
provider switch; this file does.

## Tags

| Tag | Meaning |
|---|---|
| `[ ]` | not started |
| `[~]` | in progress — the agent that claimed it writes its name |
| `[x]` | done and verified |
| `[relay-safe]` | a stand-in agent may do this unsupervised while the primary is rate-limited |
| `[relay-done]` | a stand-in finished it; **the primary must review before marking `[x]`** |

`[relay-done]` deliberately is not `[x]`. Work done by a stand-in is a draft,
not a result.

## What earns `[relay-safe]`

Mechanical, locally verifiable, cheap to revert:

- adding tests for existing behaviour
- docstrings, comments, README updates
- fixing lint and type errors
- resolving TODO comments that have an obvious single answer
- deleting dead code the tests already prove is unused

## What never gets `[relay-safe]`

- anything touching a schema, migration, or data model
- cross-file refactors
- public API or interface changes
- CI, deployment, or infrastructure config
- dependency version changes
- anything you would want to be in the room for

---

<!-- The items below are EXAMPLE entries illustrating the tags.
     Replace them with your project's real tasks. -->

## Now

- [ ] [relay-safe] Add unit tests for `parse_reset_time()` covering DST boundaries
- [ ] [relay-safe] Fix the 14 mypy errors in `src/handlers/`
- [ ] Rework the session store to use a single transaction per write

## Next

- [ ] Decide between polling and webhooks for the status feed

## Done

- [x] Wire up the StopFailure hook
