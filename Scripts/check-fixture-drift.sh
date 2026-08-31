#!/usr/bin/env bash
# Compare the live endpoints' response shapes against the captured
# fixtures.  Run deliberately, never from the test suite: the suite must
# stay offline, or it becomes flaky and network-dependent.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

keys_of() {
  python3 -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1])).keys())))' "$1"
}

status=0

# --- Platform status: public, no credential needed.
curl -fsS https://status.claude.com/api/v2/summary.json -o "$scratch/status-live.json"
live_status_keys="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["status"]; print(",".join(sorted(d.keys())))' "$scratch/status-live.json")"
for required in description indicator; do
  if [[ ",$live_status_keys," != *",$required,"* ]]; then
    echo "DRIFT: status.json no longer has status.$required" >&2
    status=1
  fi
done

# --- Usage: needs the credential.  Piped, never echoed.
token="$(security find-generic-password -s "Claude Code-credentials" -w \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])')"

http_code="$(curl -sS -o "$scratch/usage-live.json" -w '%{http_code}' \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  https://api.anthropic.com/api/oauth/usage)"
unset token

if [[ "$http_code" != "200" ]]; then
  echo "DRIFT: usage endpoint returned $http_code" >&2
  exit 1
fi

live_usage_keys="$(keys_of "$scratch/usage-live.json")"
for required in five_hour seven_day; do
  if [[ ",$live_usage_keys," != *",$required,"* ]]; then
    echo "NOTE: usage response omits $required (may be legitimate)" >&2
  fi
done

fixture="$repo_root/Packages/ClaudeUsage/Tests/ClaudeUsageTests/Fixtures/usage-both-windows.json"
for required in utilization resets_at; do
  if ! python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
w = d.get("five_hour") or d.get("seven_day") or {}
sys.exit(0 if sys.argv[2] in w else 1)' "$scratch/usage-live.json" "$required"; then
    echo "DRIFT: live window has no $required; fixture $fixture is stale" >&2
    status=1
  fi
done

# The two properties the design originally got wrong, so a regression in
# either is caught rather than rediscovered by hand.
if ! python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
w = d.get("five_hour") or d.get("seven_day") or {}
u = w.get("utilization")
sys.exit(0 if isinstance(u, (int, float)) and u > 1.0 or u == 0 else 1)' "$scratch/usage-live.json"; then
  echo "DRIFT: utilization no longer looks like a 0-100 percentage" >&2
  status=1
fi

if ! python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
w = d.get("five_hour") or d.get("seven_day") or {}
sys.exit(0 if isinstance(w.get("resets_at"), str) else 1)' "$scratch/usage-live.json"; then
  echo "DRIFT: resets_at is no longer an ISO-8601 string" >&2
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  echo "Fixtures match the live response shapes."
fi
exit "$status"
