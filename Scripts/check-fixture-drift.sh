#!/usr/bin/env bash
# Compare the live endpoints' response shapes against the captured
# fixtures.  Run deliberately, never from the test suite: the suite must
# stay offline, or it becomes flaky and network-dependent.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

compare="$repo_root/Scripts/compare-shape.py"
usage_fixture="$repo_root/Packages/ClaudeUsage/Tests/ClaudeUsageTests/Fixtures/usage-both-windows.json"
status_fixture="$repo_root/Packages/PlatformStatus/Tests/PlatformStatusTests/Fixtures/status-none.json"

status=0

# --- Platform status: public, needs no credential.
curl -fsS https://status.claude.com/api/v2/summary.json -o "$scratch/status-live.json"
python3 "$compare" \
  --fixture "$status_fixture" --live "$scratch/status-live.json" \
  --path status --keys indicator description || status=1

# --- Usage: needs the credential.  The keychain password is piped
# straight into python3 so it is never echoed, held in one variable, used
# in one header, and unset immediately afterwards.
token="$(security find-generic-password -s "Claude Code-credentials" -w \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])')"

http_code="$(curl -sS -o "$scratch/usage-live.json" -w '%{http_code}' \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  https://api.anthropic.com/api/oauth/usage)"
unset token

if [[ "$http_code" != "200" ]]; then
  echo "DRIFT: the usage endpoint returned $http_code" >&2
  exit 1
fi

for window in five_hour seven_day; do
  python3 "$compare" \
    --fixture "$usage_fixture" --live "$scratch/usage-live.json" \
    --path "$window" --keys utilization resets_at \
    --percentage utilization --optional || status=1
done

if [[ "$status" -eq 0 ]]; then
  echo "Fixtures match the live response shapes."
fi
exit "$status"
