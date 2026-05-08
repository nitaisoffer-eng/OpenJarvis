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

