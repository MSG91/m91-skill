#!/usr/bin/env bash
#
# Claude Code PreToolUse hook: ask a human on their phone before a tool runs.
#
# Claude Code blocks on this hook (synchronously, 600s default), so the alert
# has time to reach somebody and come back with an answer. Approve and the tool
# runs; reject or nobody answers and it does not.
#
#   .claude/settings.json
#   {
#     "hooks": {
#       "PreToolUse": [{
#         "matcher": "Bash",
#         "hooks": [{
#           "type": "command",
#           "if": "Bash(git push --force*)",
#           "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-code-approve.sh",
#           "timeout": 360
#         }]
#       }]
#     }
#   }
#
# Point `if` at the things worth waking somebody for — a force push, a prod
# deploy, a migration, `rm -rf`. Gating every Bash call teaches you to approve
# without reading, which is worse than no gate at all.
#
# Needs M91_SEND_LINK in the environment.
#
# FAILS OPEN, deliberately. No link configured, M91 unreachable, anything
# unexpected → exit 0 with no decision, which hands control back to Claude
# Code's own permission prompt. A broken alerting service must not brick your
# editor, and the fallback is a human being asked anyway — just on the screen
# in front of them instead of their phone.

set -uo pipefail

LINK="${M91_SEND_LINK:-}"
# Under Claude Code's hook timeout, with room for the last poll to return.
WAIT="${M91_APPROVE_TIMEOUT:-300}"
POLL="${M91_APPROVE_POLL:-5}"

# No link, no opinion.
[ -n "$LINK" ] || exit 0

payload=$(cat)

# python3 for the input parse: tool_input is nested and its values contain
# quotes and newlines, which a grep-based reader gets wrong exactly when the
# command is interesting enough to be worth approving.
read -r TOOL ACTION <<EOF
$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
ti = d.get("tool_input") or {}
# The most recognisable single line, per tool.
action = ti.get("command") or ti.get("file_path") or ti.get("path") or ti.get("url") or ""
action = " ".join(str(action).split())[:120] or d.get("tool_name", "")
print(d.get("tool_name", "tool"), action)
' 2>/dev/null)
EOF

# Could not read the event — not our call to make.
[ -n "${TOOL:-}" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g' -e 's/\r//g' |
    awk 'NR>1{printf " "} {printf "%s", $0}'
}

# One alert per tool call: tool_use_id is unique, so a retried hook cannot raise
# a second alert for the same question.
ID="claude-$(printf '%s' "$payload" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("tool_use_id","x"))' 2>/dev/null | tr -cd 'A-Za-z0-9_-' | tail -c 40)"

TITLE="Claude Code wants to run: $TOOL"
DESC="$ACTION — in $(basename "${CLAUDE_PROJECT_DIR:-$PWD}"). Nobody answering within $((WAIT / 60)) minutes is treated as a No."

body="{\"title\":\"$(json_escape "$TITLE")\",\"description\":\"$(json_escape "$DESC")\",\"severity\":\"HIGH\",\"customId\":\"$ID\",\"responseOptions\":[{\"label\":\"Approve\",\"effect\":\"SHARED\"},{\"label\":\"Reject\",\"effect\":\"SHARED\"}]}"

curl -sS --max-time 10 -X POST "$LINK" -H 'Content-Type: application/json' -d "$body" >/dev/null 2>&1 || exit 0

decide() { # decide <allow|deny> <reason>
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
    "$1" "$(json_escape "$2")"
  exit 0
}

deadline=$(( $(date +%s) + WAIT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep "$POLL"
  out=$(curl -sS --max-time 10 "$LINK/alerts/$ID" 2>/dev/null) || continue

  # Compare the LABEL. A rejection is a decision and it is truthy, so testing
  # only for the presence of `decision` would approve what somebody refused.
  case "$out" in
    *'"decision":{'*'"label":"Approve"'*)
      curl -sS --max-time 10 -X POST "$LINK/close" -H 'Content-Type: application/json' \
        -d "{\"customId\":\"$ID\"}" >/dev/null 2>&1
      decide allow "Approved on M91"
      ;;
    *'"decision":{'*'"label":"Reject"'*)
      curl -sS --max-time 10 -X POST "$LINK/close" -H 'Content-Type: application/json' \
        -d "{\"customId\":\"$ID\"}" >/dev/null 2>&1
      decide deny "Rejected on M91"
      ;;
  esac
done

# Nobody answered. Close so the next occurrence can raise a fresh alert — an
# alert left open swallows every future repeat of this customId — then deny,
# because for an approval gate silence is a No.
curl -sS --max-time 10 -X POST "$LINK/close" -H 'Content-Type: application/json' \
  -d "{\"customId\":\"$ID\"}" >/dev/null 2>&1
decide deny "No answer on M91 within $((WAIT / 60)) minutes"
