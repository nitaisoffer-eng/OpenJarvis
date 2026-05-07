#!/usr/bin/env bash
# Refresh all Google OAuth tokens for OpenJarvis connectors.
# Usage: ./scripts/refresh_google_tokens.sh
#        Or: source this before `jarvis digest --fresh`

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

uv run python -c "
import json, httpx, time, os

google_path = os.path.expanduser('~/.openjarvis/connectors/google.json')
if not os.path.exists(google_path):
    print('ERROR: No Google credentials found at', google_path)
    raise SystemExit(1)

d = json.load(open(google_path))
if not d.get('refresh_token'):
    print('ERROR: No refresh_token in', google_path)
    raise SystemExit(1)

resp = httpx.post('https://oauth2.googleapis.com/token', data={
    'client_id': d['client_id'],
    'client_secret': d['client_secret'],
    'refresh_token': d['refresh_token'],
    'grant_type': 'refresh_token',
})
resp.raise_for_status()
new = resp.json()

d['access_token'] = new['access_token']
d['expires_in'] = new.get('expires_in', 3600)
d['expires_at'] = int(time.time()) + d['expires_in']

for name in ['google', 'gmail', 'gcalendar', 'gcontacts', 'gdrive', 'google_tasks']:
    path = os.path.expanduser(f'~/.openjarvis/connectors/{name}.json')
    if os.path.exists(path):
        json.dump(d, open(path, 'w'), indent=2)
        os.chmod(path, 0o600)

print(f'Refreshed. Valid until {time.ctime(d[\"expires_at\"])}')
"
