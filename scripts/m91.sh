#!/usr/bin/env bash
#
# Raise, check and close M91 alerts from the command line.
#
# Wraps the three calls an integration ever makes, and encodes the three rules
# that hand-written curl gets wrong:
#
#   1. A 2xx does not mean anybody was reached. `delivered: 0` is a failure,
#      and this script exits 3 for it rather than looking like a success.
#   2. On close, 404 and 403 both mean "there was nothing to close" and are
#      SUCCESS. Treating them as errors logs a failure on every healthy run.
#   3. The send link is a credential in a URL. It is never printed, never
#      echoed into an error message, and never written to a log by this script.
#
# No dependencies beyond curl and a POSIX shell — no jq, no python — so it runs
# in a minimal container or a sandboxed agent environment.
#
#   ./m91.sh check
#   ./m91.sh send --title "..." [--description "..."] [--severity HIGH]
#                 [--custom-id x] [--respond "On it,Seen"] [--auto-close]
#   ./m91.sh close --custom-id x
#
# The send link comes from M91_SEND_LINK, or --link.

set -uo pipefail

VERSION="1.0.0"
LINK="${M91_SEND_LINK:-}"
TIMEOUT="${M91_TIMEOUT:-10}"

die()  { printf 'm91: %s\n' "$1" >&2; exit "${2:-1}"; }
note() { printf 'm91: %s\n' "$1" >&2; }

usage() {
  sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

# ── JSON helpers ────────────────────────────────────────────────────────────
# Extractors, not a parser. The response shapes are known and flat, so matching
# the specific keys is enough and avoids depending on jq being installed.

json_str() { # json_str <body> <key>
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 |
    sed 's/.*:[[:space:]]*"//; s/"$//'
}

json_num() { # json_num <body> <key>
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*-\{0,1\}[0-9][0-9]*" | head -1 |
    sed 's/.*:[[:space:]]*//'
}

json_true() { # json_true <body> <key>
  printf '%s' "$1" | grep -q "\"$2\"[[:space:]]*:[[:space:]]*true"
}

# Escapes a shell string for embedding in a JSON string literal. Backslash
# first, or it would double-escape the escapes it adds afterwards.
json_escape() {
  printf '%s' "$1" |
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r//g' |
    awk 'NR>1{printf "\\n"} {printf "%s", $0}'
}

# ── preflight ───────────────────────────────────────────────────────────────

require_link() {
  [ -n "$LINK" ] || die "no send link. Set M91_SEND_LINK, or pass --link <url>.
     The link comes from the M91 app: open the channel, tap the paper-plane
     icon, copy 'Send alert link'. It cannot be generated or guessed." 1

  case "$LINK" in
    https://*/s/*|http://*/s/*) ;;
    *) die "that does not look like an M91 send link. It must be the whole URL
     copied from the app, ending in /s/<token> — never rebuilt from parts." 1 ;;
  esac

  # A trailing slash makes the token a different path segment, which is a 401
  # that looks like a revoked link. Cheaper to fix here than to diagnose.
  LINK="${LINK%/}"
}

# Runs curl, capturing body and status separately. Never echoes the URL.
call() { # call <method> <url> [data]
  local method="$1" url="$2" data="${3:-}" out
  if [ -n "$data" ]; then
    out=$(curl -sS --max-time "$TIMEOUT" -X "$method" "$url" \
      -H 'Content-Type: application/json' -d "$data" -w $'\n%{http_code}' 2>&1)
  else
    out=$(curl -sS --max-time "$TIMEOUT" -X "$method" "$url" -w $'\n%{http_code}' 2>&1)
  fi
  if [ $? -ne 0 ]; then
    # curl's own message can contain the URL, and the URL is the credential.
    die "could not reach M91 (network error or timeout after ${TIMEOUT}s).
     If this environment has an outbound domain allowlist, the M91 host must
     be added to it. See README.md." 2
  fi
  STATUS="${out##*$'\n'}"
  BODY="${out%$'\n'*}"
}

api_error() { # api_error <fallback>
  local code msg
  code=$(json_str "$BODY" code)
  msg=$(json_str "$BODY" message)
  printf '%s%s' "${code:-$1}" "${msg:+ — $msg}"
}

# ── commands ────────────────────────────────────────────────────────────────

cmd_check() {
  require_link
  call GET "$LINK"
  case "$STATUS" in
    200)
      local name
      name=$(json_str "$BODY" name)
      printf 'Link is live. Channel: %s\n' "${name:-unknown}"
      note "this raised no alert — a bare link is the connection test."
      ;;
    401) die "$(api_error UNAUTHORIZED)
     The link is wrong or was revoked. Copy it again from the app." 2 ;;
    *)   die "$(api_error "HTTP $STATUS")" 2 ;;
  esac
}

cmd_send() {
  local title="" desc="" severity="" custom_id="" respond="" auto_close=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title)       title="${2:-}"; shift 2 ;;
      --description) desc="${2:-}"; shift 2 ;;
      --severity)    severity="${2:-}"; shift 2 ;;
      --custom-id)   custom_id="${2:-}"; shift 2 ;;
      --respond)     respond="${2:-}"; shift 2 ;;
      --auto-close)  auto_close=1; shift ;;
      --link)        LINK="${2:-}"; shift 2 ;;
      *) die "unknown option for send: $1" 1 ;;
    esac
  done

  require_link
  [ -n "$title" ] || die "--title is required. It is the line somebody reads on
     a locked screen, so it must say what happened and where." 1
  [ "${#title}" -ge 5 ] || die "--title must be at least 5 characters." 1

  # Uppercased so a lowercase severity is corrected rather than rejected by the
  # API — the four values are literals and this is the only spelling that works.
  if [ -n "$severity" ]; then
    severity=$(printf '%s' "$severity" | tr '[:lower:]' '[:upper:]')
    case "$severity" in
      LOW|MEDIUM|HIGH|CRITICAL) ;;
      *) die "--severity must be LOW, MEDIUM, HIGH or CRITICAL (omit it for MEDIUM)." 1 ;;
    esac
  fi

  local body="{\"title\":\"$(json_escape "$title")\""
  [ -n "$desc" ]      && body="$body,\"description\":\"$(json_escape "$desc")\""
  [ -n "$severity" ]  && body="$body,\"severity\":\"$severity\""
  [ -n "$custom_id" ] && body="$body,\"customId\":\"$(json_escape "$custom_id")\""
  [ -n "$auto_close" ] && body="$body,\"isAutoClose\":true"

  # `--respond "On it,Seen"` mirrors the link form's compact syntax: the first
  # label takes the alert for everybody (SHARED), the rest are per-person
  # (PERSONAL), and a trailing ! forces SHARED on any of them.
  if [ -n "$respond" ]; then
    local opts="" first=1 label effect
    local IFS=','
    for label in $respond; do
      label="${label#"${label%%[![:space:]]*}"}"
      label="${label%"${label##*[![:space:]]}"}"
      [ -n "$label" ] || continue
      effect=PERSONAL
      case "$label" in *!) label="${label%!}"; effect=SHARED ;; esac
      [ "$first" = 1 ] && effect=SHARED && first=0
      [ -n "$opts" ] && opts="$opts,"
      opts="$opts{\"label\":\"$(json_escape "$label")\",\"effect\":\"$effect\"}"
    done
    unset IFS
    [ -n "$opts" ] && body="$body,\"responseOptions\":[$opts]"
  fi
  body="$body}"

  call POST "$LINK" "$body"

  case "$STATUS" in
    200|201) ;;
    401) die "$(api_error UNAUTHORIZED)
     The link is wrong or was revoked. Copy it again from the app." 2 ;;
    409) die "$(api_error CHANNEL_EMPTY)
     The link works; the channel has nobody who can receive an alert. People
     must ACCEPT their invite and install M91 — an invite is not membership." 2 ;;
    429) die "$(api_error RATE_LIMITED)
     60 alerts a minute per link. This usually means a repeating condition with
     no --custom-id: add one so repeats collapse into a single alert." 2 ;;
    *)   die "$(api_error "HTTP $STATUS")" 2 ;;
  esac

  local id delivered
  id=$(json_str "$BODY" _id)
  delivered=$(json_num "$BODY" delivered)

  if json_true "$BODY" deduplicated; then
    printf 'Not re-alerted: that alert is already open (id %s).\n' "${id:-?}"
    note "this is deduplication working. Close it, or change the customId, to raise a new one."
    return 0
  fi

  if [ "${delivered:-0}" -eq 0 ]; then
    printf 'Alert raised (id %s) but delivered to 0 people.\n' "${id:-?}"
    die "nobody was reached. Check that members accepted their invites and
     have M91 installed." 3
  fi

  printf 'Alert raised (id %s), delivered to %s.\n' "${id:-?}" "$delivered"
}

cmd_close() {
  local custom_id="" alert_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --custom-id) custom_id="${2:-}"; shift 2 ;;
      --alert-id)  alert_id="${2:-}"; shift 2 ;;
      --link)      LINK="${2:-}"; shift 2 ;;
      *) die "unknown option for close: $1" 1 ;;
    esac
  done

  require_link
  [ -n "$custom_id" ] || [ -n "$alert_id" ] || \
    die "close needs --custom-id (what your system calls the problem) or --alert-id." 1

  local body
  if [ -n "$custom_id" ]; then
    body="{\"customId\":\"$(json_escape "$custom_id")\"}"
  else
    body="{\"alertId\":\"$(json_escape "$alert_id")\"}"
  fi

  call POST "$LINK/close" "$body"

  case "$STATUS" in
    200) printf 'Closed.\n' ;;
    # Both mean there was nothing to close. This is the normal result on a
    # healthy run — the condition never went bad, or a person already closed it.
    # Exiting non-zero here is what makes monitoring scripts log a daily error.
    404|403) printf 'Nothing to close.\n' ;;
    401) die "$(api_error UNAUTHORIZED)
     The link is wrong or was revoked. Copy it again from the app." 2 ;;
    *)   die "$(api_error "HTTP $STATUS")" 2 ;;
  esac
}

# ── entry ───────────────────────────────────────────────────────────────────

[ $# -gt 0 ] || usage 1
case "$1" in
  check)  shift; [ "${1:-}" = "--link" ] && { LINK="${2:-}"; shift 2; }; cmd_check "$@" ;;
  send)   shift; cmd_send "$@" ;;
  close)  shift; cmd_close "$@" ;;
  -h|--help|help) usage 0 ;;
  --version) printf 'm91.sh %s\n' "$VERSION" ;;
  *) die "unknown command: $1 (expected check, send or close)" 1 ;;
esac
