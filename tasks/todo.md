# Phase 7 — Bug stabilization, droplet migration, browser layer


## Goal

Stabilize Phase 1-3, migrate OpenJarvis from Mac to a dedicated production droplet, deploy Auto Browser as a sidecar, and ship the first browser-aware skill (Skool harvest). After Phase 7, OpenJarvis is the single combined system: information layer + action layer.

## Architectural decisions (locked)

- **Droplet:** DigitalOcean, 8GB / 4 vCPU, Ubuntu 24.04 LTS, SFO3 region
- **Remote access:** Tailscale only (no public ingress except SSH)
- **Hosting model:** Droplet is production / always-on. Mac is dev mirror only.
- **Auto Browser:** Docker sidecar on the same droplet, OpenJarvis is the only MCP client
- **Orchestrator:** OpenJarvis-native scheduler + memory-as-state (no Prefect, no Temporal — verified `scheduler/` is sufficient via tick-based + persistent task store + idempotent agents)
- **Notifications:** ntfy.sh (free public broker, topic-based)
- **Secrets:** systemd unit env vars + `/etc/environment` for now. Revisit Infisical only if scope grows.

## Phase 7.0 — Bug stabilization [BLOCKING all subsequent steps]

Fix the three known bugs before any new work. These cause friction every day; fixing them is also the cleanest test that the codebase is healthy enough to refactor.

- [x] **Bug A: `jarvis digest --fresh` exits before audio plays/caches**
  - [x] Reproduce, capture logs
  - [x] Identify race condition in CLI exit vs audio cache write
  - [x] Patch `cli/digest.py` (or wherever digest CLI lives) to await audio cache before returning
  - [x] Verify: `jarvis digest --fresh` plays through and audio file exists in cache after exit
  - [x] Update `tasks/lessons.md` with root cause

- [x] **Bug B: `connect --list` reports "connected" with token-less connector files**
  - [x] Reproduce by removing tokens from a connector JSON
  - [x] Add token-presence validation (surgical: gmail.py only, matches gdrive/gcalendar pattern) to `ConnectorRegistry.list_connectors()` or equivalent
  - [ ] Status should reflect `connected | needs_auth | broken`, not just bool
  - [ ] Verify: `connect --list` shows accurate state for each connector

- [x] **Bug C: Connector token refresh not implemented**
  - [x] Find connector base class
  - [x] Add automatic refresh-on-401 using stored `refresh_token`
  - [x] On refresh: update connector JSON with new tokens atomically
  - [x] Verify: let an access token expire, run `jarvis digest`, confirm auto-refresh happens
  - [x] Delete the manual `refresh_google_tokens.sh` workaround

- [ ] **Bug D: `jarvis digest` reports "No digest for today" after local-day rolls over UTC midnight**
  - [ ] Reproduce: confirm `digest_store.get_today()` builds a UTC date pattern (`datetime.now(ZoneInfo("UTC")).strftime("%Y-%m-%d")`) but compares it against `generated_at` timestamps stored in naive local time
  - [ ] Decide fix: (a) pass system local TZ to `get_today()` from `digest_cmd.py`, or (b) store timestamps in UTC at write time, or (c) both
  - [ ] Verify: at 17:00 PT (00:00 UTC the next day), `jarvis digest` returns today's digest, not "No digest for today"
  - [ ] Audit other date-based queries in `digest_store.py` (history, get_by_date) for the same bug

- [ ] **Side fix: Tilde expansion in `file_read`** (low effort, ship it while we're here)
  - [ ] Add `os.path.expanduser` to `tools/file_read.py` allowed_dirs and path inputs
  - [ ] Verify: `file_read` accepts `~/Documents/foo.txt`

**VERIFICATION CHECKPOINT 7.0:** All four bugs fixed, all four verifications pass, `tasks/lessons.md` updated. No phase 7.1 work until this is green.

## Phase 7.1 — Droplet provisioning + remote access

- [ ] Create DigitalOcean droplet
  - [ ] 8GB / 4 vCPU, Ubuntu 24.04 LTS, SFO3
  - [ ] SSH key added during creation (use existing key or generate new one)
  - [ ] Note IP, save to `~/OpenJarvis/docs/decisions/001-droplet-migration.md`
- [ ] Tailscale setup
  - [ ] Sign up at tailscale.com if not already
  - [ ] Install Tailscale on droplet (`curl -fsSL https://tailscale.com/install.sh | sh`)
  - [ ] `sudo tailscale up` and authenticate
  - [ ] Install Tailscale on Mac (App Store or download)
  - [ ] Install Tailscale on iPhone (App Store)
  - [ ] If not already, add Kashy droplet to the same Tailnet
  - [ ] Verify: ping droplet's Tailscale IP from Mac and iPhone
- [ ] Firewall hardening
  - [ ] `ufw default deny incoming`
  - [ ] `ufw allow 22/tcp` (SSH from anywhere — Tailscale-aware ACL refinement is later)
  - [ ] `ufw allow in on tailscale0` (any port via Tailscale interface)
  - [ ] `ufw enable`
  - [ ] Verify: from a non-Tailnet device, droplet ports 8000/6080 are unreachable
  - [ ] Verify: from Tailnet, droplet ports 8000/6080 are reachable
- [ ] SSH hardening
  - [ ] Disable password auth in `/etc/ssh/sshd_config` (`PasswordAuthentication no`)
  - [ ] Reload sshd
  - [ ] Verify: password login rejected, key login works
- [ ] Non-root user
  - [ ] Create `nate` user with sudo
  - [ ] Copy SSH keys
  - [ ] Use `nate` for all OpenJarvis ops; reserve root for system maintenance only

**VERIFICATION CHECKPOINT 7.1:** Droplet provisioned, Tailnet reaches it, public internet only sees SSH, non-root user functional.

## Phase 7.2 — OpenJarvis migration to droplet

- [ ] Install dependencies
  - [ ] Python 3.10+ via system or `uv`
  - [ ] Node.js 22+ (for ClaudeCodeAgent and WhatsApp channel, even if unused initially)
  - [ ] Rust toolchain (`curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`)
  - [ ] Docker + docker-compose (for Auto Browser later)
  - [ ] `uv` package manager
- [ ] Clone OpenJarvis to `/opt/openjarvis`
  - [ ] `git clone <my-fork-or-upstream> /opt/openjarvis`
  - [ ] If using my fork with custom skills, document the fork URL in instructions
  - [ ] `cd /opt/openjarvis && uv sync`
  - [ ] Build Rust extension: `uv run maturin develop -m rust/crates/openjarvis-python/Cargo.toml`
- [ ] Migrate config
  - [ ] Create `/home/nate/.openjarvis/` with proper perms
  - [ ] Copy + adapt `config.toml` from Mac (paths change, otherwise same)
  - [ ] Copy connectors directory
  - [ ] Set `CARTESIA_API_KEY`, `ANTHROPIC_API_KEY`, `AUTO_BROWSER_TOKEN`, `NTFY_TOPIC` in `/etc/environment` or systemd unit
- [ ] Migrate memory + traces + telemetry DBs (optional — clean start is also valid)
  - [ ] Decision: clean start (less complexity, better signal)
- [ ] First smoke test on droplet
  - [ ] `jarvis doctor` passes
  - [ ] `jarvis ask "test"` returns successfully
  - [ ] `jarvis connect gmail` (re-OAuth from droplet — may need new OAuth client or shared OAuth)
  - [ ] `jarvis digest` runs (audio caches to disk; download to Mac for playback)
- [ ] systemd unit for OpenJarvis API server
  - [ ] `/etc/systemd/system/openjarvis.service` runs `jarvis serve --port 8000`
  - [ ] Auto-restart on failure
  - [ ] Bind to `0.0.0.0` so Tailscale clients reach it (firewall blocks public)
- [ ] systemd unit for OpenJarvis scheduler
  - [ ] `/etc/systemd/system/openjarvis-scheduler.service` runs `jarvis scheduler start`
  - [ ] Auto-restart on failure
- [ ] Verify dashboard reachable from Mac via Tailscale IP

**VERIFICATION CHECKPOINT 7.2:** OpenJarvis fully operational on droplet, Phase 1-3 features working, scheduler running, accessible via Tailscale from Mac and iPhone.

## Phase 7.3 — Auto Browser sidecar deployment

- [ ] Clone Auto Browser to `/opt/auto-browser`
- [ ] Configure `.env` for production
  - [ ] `APP_ENV=production`
  - [ ] `API_BEARER_TOKEN=<strong random>` (matches `AUTO_BROWSER_TOKEN` in OpenJarvis env)
  - [ ] `REQUIRE_OPERATOR_ID=true`
  - [ ] `AUTH_STATE_ENCRYPTION_KEY=<44-char fernet key>`
  - [ ] `REQUIRE_AUTH_STATE_ENCRYPTION=true`
  - [ ] `REQUEST_RATE_LIMIT_ENABLED=true`
  - [ ] `STEALTH_ENABLED=false`
  - [ ] `MAX_SESSIONS=3` (start small, scale up if needed)
  - [ ] Bind ports to docker network only — OpenJarvis reaches it via container DNS
- [ ] `docker compose up -d`
- [ ] Verify Auto Browser API reachable from OpenJarvis container/host
  - [ ] `curl -H "Authorization: Bearer $AUTO_BROWSER_TOKEN" http://localhost:8000/healthz`
- [ ] Verify noVNC reachable via Tailscale (for human takeover)
  - [ ] Open `http://[droplet-tailscale-ip]:6080/vnc.html` from Mac
- [ ] Set up artifact retention policy (default 168 hours = 7 days, adjust if needed)

**VERIFICATION CHECKPOINT 7.3:** Auto Browser running, health check passes, noVNC reachable, OpenJarvis can reach the API endpoint.

## Phase 7.4 — `browser` tool implementation

- [ ] Create `src/openjarvis/tools/browser.py`
  - [ ] `BrowserTool(BaseTool)` class
  - [ ] Methods exposed via `execute(action=..., **params)`:
    - [ ] `create_session(name, start_url, auth_profile=None)`
    - [ ] `observe(session_id)` — returns DOM summary, screenshot, interactables
    - [ ] `navigate(session_id, url)`
    - [ ] `click(session_id, element_id)`
    - [ ] `type(session_id, element_id, text, sensitive=False)`
    - [ ] `scroll(session_id, delta_y)`
    - [ ] `screenshot(session_id, label)`
    - [ ] `save_auth_profile(session_id, profile_name)`
    - [ ] `request_takeover(session_id, reason)`
    - [ ] `close_session(session_id)`
  - [ ] Each method calls Auto Browser MCP via `httpx` with bearer token
  - [ ] Approval-gated actions (`type` with `sensitive=True`, any future `upload`, etc.) emit `BROWSER_APPROVAL_PENDING` event before executing
- [ ] Register tool with `@ToolRegistry.register("browser")`
- [ ] Add to default `tools` list in config
- [ ] Tests in `tests/tools/test_browser.py`
  - [ ] Mock Auto Browser API responses
  - [ ] Verify each action produces the right HTTP call
  - [ ] Verify approval-gated actions emit the expected event

**VERIFICATION CHECKPOINT 7.4:** `jarvis ask -a orchestrator --tools browser "Open example.com and tell me the page title"` works end-to-end.

## Phase 7.5 — `BrowserAuthProfile` connector type

- [ ] Add new connector class in `src/openjarvis/connectors/browser_auth.py`
  - [ ] Stores: `profile_name`, `domain`, `session_cookies`, `local_storage`, `created_at`, `last_used`
  - [ ] Encrypted at rest using same key as Auto Browser auth profiles
  - [ ] One file per profile: `~/.openjarvis/connectors/browser_<profile_name>.json`
- [ ] CLI extension: `jarvis connect browser <profile_name> --url <login_url>`
  - [ ] Creates Auto Browser session at login URL
  - [ ] Prompts user to complete login via noVNC
  - [ ] On confirmation, calls `save_auth_profile` and writes connector JSON
  - [ ] Adds entry to connector registry
- [ ] `connect --list` shows browser profiles alongside OAuth ones (with bug B fix from Phase 7.0)

**VERIFICATION CHECKPOINT 7.5:** Can run `jarvis connect browser skool --url https://www.skool.com/...`, log in via noVNC, profile is saved and listable.

## Phase 7.6 — First browser skill: Skool harvest

- [ ] Create skill at `src/openjarvis/skills/skool_harvest/`
  - [ ] `__init__.py`, `skill.py`, `README.md`, `tasks/todo.md`
- [ ] Skill metadata: name, description, required tools (`browser`, `memory.ingest`), required connectors (`browser_skool`)
- [ ] Implementation phases (mirrors original Skool plan):
  - [ ] Walk classroom → JSON tree of modules/lessons (idempotent: store tree in memory)
  - [ ] Per-lesson DOM extraction (idempotent: skip lessons already in memory)
  - [ ] Network inspector wired to capture video manifest URLs during extraction
  - [ ] Video download via `yt-dlp` (new tool: `tools/yt_dlp.py`)
  - [ ] Transcription via `faster-whisper` (new tool: `tools/whisper.py`)
  - [ ] Final ingest into OpenJarvis memory with tags `skool`, `<community-name>`, `<module-id>`
- [ ] CLI: `jarvis skill run skool_harvest --community <name>`
- [ ] Schedule: `jarvis scheduler create --skill skool_harvest --schedule "0 3 * * 0" --args community=<name>` (weekly Sunday 3am)
- [ ] Memory queries work: `jarvis ask "what did the Skool course say about X"` → orchestrator pulls from memory

**VERIFICATION CHECKPOINT 7.6:** Skool community fully harvested into memory, agent can answer questions about course content with citations to specific lessons.

## Phase 7.7 — ntfy.sh notification channel

- [ ] Create `src/openjarvis/channels/ntfy.py`
  - [ ] Outbound only: send notification to topic
  - [ ] Inbound (webhook): receive approval taps from phone
  - [ ] Topic stored in `NTFY_TOPIC` env var
- [ ] Wire to approval gates: when browser tool emits `BROWSER_APPROVAL_PENDING`, ntfy channel sends notification with deep link to approval UI
- [ ] Tap notification on phone → opens Auto Browser approval URL via Tailscale → tap approve → Auto Browser unblocks the action
- [ ] Wire daily digest summary to ntfy (optional alternative to TTS playback)

**VERIFICATION CHECKPOINT 7.7:** Trigger a write action that requires approval, get phone notification, tap-approve, action executes.

## Phase 7.8 — Read-only Kashy connector

- [ ] On Kashy droplet: expose read-only API endpoint over Tailscale
  - [ ] `GET /state` returns current positions, PnL, drawdown breaker status, last error
  - [ ] Bearer-token auth, listening only on Tailscale interface
- [ ] On OpenJarvis droplet: create `src/openjarvis/connectors/kashy.py`
  - [ ] Polls Kashy state every N minutes (configurable)
  - [ ] Ingests state snapshots into memory with tag `kashy`
- [ ] Verify cross-system reasoning: `jask "how is Kashy doing today, and should I run aggressive HPG outreach?"` — orchestrator pulls Kashy state from memory and reasons over it

**VERIFICATION CHECKPOINT 7.8:** Kashy state queryable from OpenJarvis memory, no write path exists yet (Phase 11 territory).

## Phase 7 — Final review & lessons capture

- [ ] Update `tasks/lessons.md` with everything learned during Phase 7
- [ ] Document architecture decisions as ADRs in `docs/decisions/`:
  - [ ] `001-droplet-migration.md`
  - [ ] `002-auto-browser-sidecar.md`
  - [ ] `003-no-prefect-use-native-scheduler.md`
  - [ ] `004-cookie-auth-as-connector-type.md`
- [ ] Mark Phase 7 complete in roadmap
- [ ] Plan Phase 8 (Code assistant skills) in next planning session

---

## Phase 7 verification — "would this hold up in production for a real business?"

Before declaring Phase 7 done:

- [ ] Droplet survives reboot — all services come back automatically
- [ ] Auto Browser session persistence — auth profiles survive container restart
- [ ] Memory persistence — restart OpenJarvis, memory queries still return previously-ingested content
- [ ] Notification flow — reproduce the approval flow end-to-end on a fresh device
- [ ] Skool re-harvest — run twice in a row, second run should detect no new content (idempotency proof)
- [ ] No public exposure — port scan from outside the Tailnet shows only port 22

If any check fails, fix before moving to Phase 8.

---

## 📍 Next session entry point (updated 2026-05-12)

**Status:** Bugs A, B, C done. Commits `e4564a8`, `7ef534f`, `421e135`, `c60bc7b` on `origin/main`.

**Start here next time:** Bug D — `digest_store.get_today()` timezone mismatch (line ~42 of this file).

**Quick context for Bug D (diagnosis already done):**
- `digest_store.get_today()` defaults to `timezone_name="UTC"`, builds today's date pattern via `datetime.now(ZoneInfo("UTC")).strftime("%Y-%m-%d")` → e.g. `"2026-05-13"`.
- But `generated_at` is stored as naive local time (e.g. `"2026-05-12T17:01:53"` when generated at 5pm PT).
- After ~5pm PT, local date != UTC date, so the LIKE pattern misses and `get_today()` returns None → CLI prints "No digest for today" even when one exists.
- Surfaced during Bug C verification; the digest itself works fine.

**Likely fix:** `digest_cmd.py` passes a system local TZ to `get_today()` instead of relying on the `"UTC"` default. Or store timestamps in UTC at write time. Or both. Probably 5-10 lines total.

**Also still open after Bug D:**
- Side fix: tilde expansion in `file_read` tool
- Bug B's deferred sub-items: three-state status enum + audit of 22 other `is_connected()` implementations
- `is_connected()` in `google_tasks.py` still uses file-only check (same shape as Bug B's gmail fix, deliberately left for later)

**Then Phase 7.0 verification checkpoint → droplet provisioning (Phase 7.1).**
