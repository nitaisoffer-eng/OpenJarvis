# Lessons learned

> Capture patterns and root causes after corrections so we don't repeat mistakes.

## Compounding bugs can mask each other

**Date:** 2026-05-07
**Context:** Bug A — `jarvis digest --fresh` audio playback (`src/openjarvis/cli/digest_cmd.py`)

### What happened
Bug A presented as one symptom — "`--fresh` exits before audio plays" — but
was actually two independent bugs in `digest_cmd.py` that compounded:

- **A1:** `--fresh` branch had a bare `return` after generation (line 193),
  so it never reached the cache-load + playback block at line 220.
- **A2:** Non-fresh playback spawned a `daemon=True` thread to call
  `_play_audio` and then exited the function with no `join()`. Process exit
  killed the daemon thread mid-playback.

A1 made A2 invisible: `--fresh` never reached the playback path, so the
daemon-no-join bug stayed hidden. A2 made A1 look like a TTS issue: even if
A1 had been "fixed" alone, the playback path it now reached was broken too,
so audio still wouldn't play.

### Lesson
**When a bug seems to confirm a single fault, also test the adjacent code
path before claiming the fix works. Symptoms can collide.**

### Reproduction protocol going forward
For any CLI bug, test both the "trigger" flag and the equivalent baseline
(e.g., `--fresh` AND the cached path). Compare behaviors:
- Both fail → bug is in shared code below the branch
- Only one fails → bug is in the divergent code

### Patch
Two surgical edits to `digest_cmd.py`:
1. Removed the success-case `return` in the `--fresh` branch; let it fall
   through to the cache-load + playback block.
2. Added `audio_thread.join()` after `console.print(Markdown(text))` in the
   playback block, so the CLI waits for audio to finish before exiting.

## Drift between sibling files in the same codebase

**Date:** 2026-05-07
**Context:** Bug B — `connect --list` false positive (`src/openjarvis/connectors/gmail.py`)

### What happened
`gmail.py`'s `is_connected()` returned `True` for any non-empty token dict,
including dicts that only contained `client_id`/`client_secret` with no
actual access token. Meanwhile, `gdrive.py` and `gcalendar.py` — sibling
files implementing the same OAuth pattern — already had the correct check:
`bool(tokens.get("access_token") or tokens.get("token"))`.

The bug was in gmail.py alone, with the comment in-source even admitting
it: *"simplified: real impl would also check expiry / refresh token"*.

### Lesson
**Before writing a fix, scan the siblings.** When N files implement the
same pattern, one of them is often already correct. Diff the broken file
against the working ones before designing a new fix — copy the working
pattern instead of inventing.

### Why this scope and not bigger
The todo entry described an ideal "three-state status: `connected | needs_auth
| broken`" — that would touch the registry, CLI display, and 24 other
connectors. The actual symptom (false positive on token-less files) is
fixed with two lines in one file by matching the sibling pattern. The
bigger refactor is a separate concern; capture it as a future todo if it
matters operationally, not because the docstring aspires to it.

### Patch
One method body in `gmail.py`. Match the existing `gdrive.py`/`gcalendar.py`
implementation verbatim:
```python
return bool(tokens.get("access_token") or tokens.get("token"))
```

### Bonus catch
This bug originally surfaced during Bug A debugging, when `--list` reported
all six Google connectors as `connected` even though every refresh token
was 7-day-expired. The fix here doesn't catch expired tokens (that's a
separate bug — connector-layer token refresh on 401, still in the todo
backlog). But it does catch the "deleted access_token, refresh_token
present" case, which is the common false-positive shape.
