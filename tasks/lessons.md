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
## Auto-refresh OAuth tokens at the connector layer

**Date:** 2026-05-12
**Context:** Bug C — connector token refresh
(`src/openjarvis/connectors/oauth.py`, `gmail.py`, `gdrive.py`, `gcalendar.py`,
`gcontacts.py`, `google_tasks.py`)

### What happened
Until this fix, Google access tokens expired (hourly under normal operation,
or every 7 days for refresh tokens while the OAuth app stayed in "Testing"
mode). The workaround was `scripts/refresh_google_tokens.sh`, a shell script
that had to be run manually before each `jarvis digest`. Bug C moves the
refresh primitive into the codebase so it fires on 401 automatically.

### Design choices
- **One primitive, many call sites.** `refresh_access_token(credentials_path)`
  lives in `oauth.py` next to the existing `_exchange_token`. Each
  connector's API helpers call it inline on 401, then retry once.
- **Atomic write.** Refreshed payload is written to a `.tmp` sibling, fsynced,
  then `os.replace`d onto the real file. POSIX rename is atomic within a
  filesystem, so a concurrent reader never sees a half-written JSON.
- **Sibling fan-out.** Google issues one credential set per OAuth flow but
  OpenJarvis stores it in six files (`google.json`, `gmail.json`,
  `gcalendar.json`, `gcontacts.json`, `gdrive.json`, `google_tasks.json`).
  When any of these is refreshed, the new tokens are fanned out to the
  other five so they don't drift apart.
- **Carry refresh_token forward.** Google omits `refresh_token` from refresh
  responses (it doesn't rotate). The fix explicitly preserves the existing
  one; a naive `tokens.update(new)` would have erased it after the first
  refresh.
- **Token shape stays canonical.** Same 6 fields as the existing
  `_exchange_token` writes, plus an `expires_at` (epoch seconds) so future
  proactive-expiry logic has the right field name to read.

### Connector wiring pattern
Each connector's low-level API helper switched from taking `token: str` to
taking `credentials_path: str`. Inside, the call does load_tokens → httpx →
on 401 refresh_access_token → retry once → raise_for_status. Trade-off:
each API call loads tokens from disk. For the digest (≤10 API calls per
run) this is negligible. For a high-throughput sync it would matter — then
an in-memory token cache with a TTL would be appropriate. Surgical scope
first.

### Why each connector got patched individually instead of a base-class hook
Looked at the BaseConnector ABC; it has `is_connected`, `disconnect`,
`sync`, `sync_status` — nothing about HTTP. There's no shared HTTP layer
either; every connector hand-rolls `httpx` calls. Adding an abstract
`authed_get` to the base class would have touched 25 implementations to no
benefit when only 5 of them are Google OAuth. Per-connector patches stayed
mechanical: same shape across gmail/gdrive/gcalendar/gcontacts, slightly
different shape for google_tasks (one generic helper, two call sites).

### Verification
Forced 401 by overwriting `access_token` with a sentinel string in all six
Google connector files, ran `jarvis digest --fresh`, watched a new digest
row land in `digest.db` with sources `[gmail, hackernews, google_tasks,
gcalendar]`. After the run, all touched connector files showed real fresh
access tokens (not the sentinel). Sibling fan-out worked.

### Lesson 1 (architectural)
**Token refresh belongs at the lowest layer that knows about HTTP, not at
the agent layer.** The agent shouldn't care that auth happens to be OAuth.
Putting refresh-on-401 in the connector's API helpers means every existing
call site — sync, MCP tools, ad-hoc scripts — benefits without changes.

### Lesson 2 (process, Bug A reapplied)
**Testing the layer you patched does not prove the system works.** The
direct `_gmail_api_list_messages` test confirmed refresh fires and retries
succeed. But the end-to-end digest test surfaced an *unrelated* bug
(`digest_store.get_today()` uses UTC date pattern against locally-named
timestamps — logged as Bug D in todo.md). The lesson holds: test the
adjacent path, in this case the actual user-facing command, before
declaring done.

### Out of scope (intentional)
- Non-Google OAuth (strava, notion, dropbox, slack) — different refresh
  semantics per provider; deferred until any of them becomes a daily
  dependency.
- Channel-layer Gmail (`channels/gmail.py`) — separate codebase with
  separate token storage. The digest doesn't use it. Tracked separately.
- Proactive expiry checking before each call — reactive 401 handling is
  enough; clocks drift and tokens can be revoked anyway, so the 401 path
  is the only truly reliable signal.
- `is_connected()` in `google_tasks.py` still uses file-existence check
  (same shape as the Bug B we fixed in gmail.py). Left untouched to keep
  the Bug C commit clean.

