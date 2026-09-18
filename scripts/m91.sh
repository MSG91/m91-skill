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
#
# A platform alerting its OWN users by phone number uses an API key instead —
# one secret for the whole account, the person named in each call, rather than
# a send link per person. This is a DIFFERENT credential for a DIFFERENT job:
# it can alert one person, never a channel, and it cannot mint a send link or
# record a response. See platform-api.md.
#
#   ./m91.sh invite --phone 919876543210 [--label "Acme CRM"]
#   ./m91.sh alert --phone 919876543210 --title "..." [--severity HIGH]
#                  [--custom-id x] [--respond "Approve!,Reject!"]
#   ./m91.sh decision --phone 919876543210 --custom-id x
#   ./m91.sh close-person --phone 919876543210 --custom-id x
#   ./m91.sh remove --phone 919876543210
#
# The API key comes from M91_API_KEY, or --api-key. The host it calls comes
# from M91_API, or --api (default: the hosted M91 API).

set -uo pipefail

VERSION="1.1.0"
LINK="${M91_SEND_LINK:-}"
TIMEOUT="${M91_TIMEOUT:-10}"

# The platform-API pair. Separate from LINK/TIMEOUT's job on purpose: a send
# link addresses a channel by BEING its secret; an API key addresses a person
# BY NAME against a fixed host, so it needs a host to call, not a per-target URL.
API_KEY="${M91_API_KEY:-}"
API_HOST="${M91_API:-https://siren-backend-1091285226236.asia-south1.run.app}"

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

require_api_key() {
  [ -n "$API_KEY" ] || die "no API key. Set M91_API_KEY, or pass --api-key <key>.
     A key comes from the M91 app: Settings -> Advanced settings -> API keys -> Create. It is shown
     ONCE and cannot be retrieved again — mint a new one if you lost it." 1

  case "$API_KEY" in
    m91sk_*) ;;
    *) die "that does not look like an M91 API key. It must start with
     m91sk_ and be copied whole, straight from the app." 1 ;;
  esac

  API_HOST="${API_HOST%/}"
}

# Runs curl, capturing body and status separately. Never echoes the URL — a
# send link IS a credential, and even for an API key call the phone number in
# the body is not something to leave lying around in a script's own output.
call() { # call <method> <url> [data]
  local method="$1" url="$2" data="${3:-}" out
  local -a auth=()
  # AUTH_HEADER is set by the caller (require_api_key path) or left empty for
  # the send-link path, which authenticates via the token already in the URL.
  [ -n "${AUTH_HEADER:-}" ] && auth=(-H "$AUTH_HEADER")
  if [ -n "$data" ]; then
    out=$(curl -sS --max-time "$TIMEOUT" -X "$method" "$url" \
      "${auth[@]}" -H 'Content-Type: application/json' -d "$data" -w $'\n%{http_code}' 2>&1)
  else
    out=$(curl -sS --max-time "$TIMEOUT" -X "$method" "$url" \
      "${auth[@]}" -w $'\n%{http_code}' 2>&1)
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

# ── platform-API commands (API key, not a send link) ────────────────────────
#
# Different auth, different addressing, same JSON helpers and the same rules
# about what a 2xx does and does not prove. `phone` replaces the channel the
# send link implies; nothing else about reading a response changes.

cmd_invite() {
  local phone="" label=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --phone)   phone="${2:-}"; shift 2 ;;
      --label)   label="${2:-}"; shift 2 ;;
      --api-key) API_KEY="${2:-}"; shift 2 ;;
      --api)     API_HOST="${2:-}"; shift 2 ;;
      *) die "unknown option for invite: $1" 1 ;;
    esac
  done

  require_api_key
  [ -n "$phone" ] || die "--phone is required. Country code, no +
     (e.g. 919876543210) — the same format the app itself asks for." 1

  local body="{\"phone\":\"$(json_escape "$phone")\""
  [ -n "$label" ] && body="$body,\"label\":\"$(json_escape "$label")\""
  body="$body}"

  AUTH_HEADER="Authorization: Bearer $API_KEY" call POST "$API_HOST/api/v1/recipients" "$body"

  case "$STATUS" in
    200|201) ;;
    401) die "$(api_error UNAUTHORIZED)
     The key is wrong or was revoked. Mint a new one from the app." 2 ;;
    *)   die "$(api_error "HTTP $STATUS")" 2 ;;
  esac

  local state
  state=$(json_str "$BODY" state)
  case "$state" in
    accepted) printf 'Already accepted. %s is reachable.\n' "$phone" ;;
    pending)  printf 'Invited. %s is NOT reachable yet — they must install M91,
     sign in with this exact number, and accept.\n' "$phone" ;;
    declined) printf '%s declined previously.\n' "$phone"
      note "this is terminal. Only they can undo it, from their own app." ;;
    *) printf 'Invited. state=%s\n' "${state:-unknown}" ;;
  esac
}

cmd_remove() {
  local phone=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --phone)   phone="${2:-}"; shift 2 ;;
      --api-key) API_KEY="${2:-}"; shift 2 ;;
      --api)     API_HOST="${2:-}"; shift 2 ;;
      *) die "unknown option for remove: $1" 1 ;;
    esac
  done

  require_api_key
  [ -n "$phone" ] || die "--phone is required." 1

  AUTH_HEADER="Authorization: Bearer $API_KEY" call DELETE "$API_HOST/api/v1/recipients/$phone"

  case "$STATUS" in
    200) printf 'Removed. %s will no longer be alerted.\n' "$phone" ;;
    401) die "$(api_error UNAUTHORIZED)
     The key is wrong or was revoked. Mint a new one from the app." 2 ;;
    *)   die "$(api_error "HTTP $STATUS")" 2 ;;
  esac
}

cmd_alert() {
  local phone="" title="" desc="" severity="" custom_id="" respond=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --phone)       phone="${2:-}"; shift 2 ;;
      --title)       title="${2:-}"; shift 2 ;;
      --description) desc="${2:-}"; shift 2 ;;
      --severity)    severity="${2:-}"; shift 2 ;;
      --custom-id)   custom_id="${2:-}"; shift 2 ;;
      --respond)     respond="${2:-}"; shift 2 ;;
      --api-key)     API_KEY="${2:-}"; shift 2 ;;
      --api)         API_HOST="${2:-}"; shift 2 ;;
      *) die "unknown option for alert: $1" 1 ;;
    esac
  done

  require_api_key
  [ -n "$phone" ] || die "--phone is required — the API key alerts ONE PERSON,
     never a channel. That is still the send link's job." 1
  [ -n "$title" ] || die "--title is required. It is the line somebody reads on
     a locked screen, so it must say what happened and where." 1
  [ "${#title}" -ge 5 ] || die "--title must be at least 5 characters." 1

  if [ -n "$severity" ]; then
    severity=$(printf '%s' "$severity" | tr '[:lower:]' '[:upper:]')
    case "$severity" in
      LOW|MEDIUM|HIGH|CRITICAL) ;;
      *) die "--severity must be LOW, MEDIUM, HIGH or CRITICAL (omit it for MEDIUM)." 1 ;;
    esac
  fi

  local body="{\"phone\":\"$(json_escape "$phone")\",\"title\":\"$(json_escape "$title")\""
  [ -n "$desc" ]      && body="$body,\"description\":\"$(json_escape "$desc")\""
  [ -n "$severity" ]  && body="$body,\"severity\":\"$severity\""
  [ -n "$custom_id" ] && body="$body,\"customId\":\"$(json_escape "$custom_id")\""

  # Same compact syntax as `send --respond`: first label SHARED, rest PERSONAL,
  # trailing ! forces SHARED. On a one-person channel PERSONAL is dead weight —
  # there is nobody left to acknowledge to — so `alert` almost always wants
  # every option forced SHARED with `!`, e.g. "Approve!,Reject!".
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

  AUTH_HEADER="Authorization: Bearer $API_KEY" call POST "$API_HOST/api/v1/alerts" "$body"

  case "$STATUS" in
    200|201) ;;
    401) die "$(api_error UNAUTHORIZED)
     The key is wrong or was revoked. Mint a new one from the app." 2 ;;
    404) die "$(api_error NOT_FOUND)
     $phone has never accepted an invite from this account. Run
     './m91.sh invite --phone $phone' first, and wait for them to accept." 2 ;;
    429) die "$(api_error RATE_LIMITED)
     Sends are limited per key. This usually means a repeating condition with
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
    die "$phone has not accepted, or has no device registered." 3
  fi

  printf 'Alert raised (id %s), delivered.\n' "${id:-?}"
}

cmd_decision() {
  local phone="" custom_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --phone)     phone="${2:-}"; shift 2 ;;
      --custom-id) custom_id="${2:-}"; shift 2 ;;
      --api-key)   API_KEY="${2:-}"; shift 2 ;;
      --api)       API_HOST="${2:-}"; shift 2 ;;
      *) die "unknown option for decision: $1" 1 ;;
    esac
  done

  require_api_key
  [ -n "$phone" ] || die "--phone is required." 1
  [ -n "$custom_id" ] || die "--custom-id is required — the id you raised the
     alert with." 1

  AUTH_HEADER="Authorization: Bearer $API_KEY" \
    call GET "$API_HOST/api/v1/alerts/$custom_id?phone=$phone"

  case "$STATUS" in
    200) ;;
    401) die "$(api_error UNAUTHORIZED)
     The key is wrong or was revoked. Mint a new one from the app." 2 ;;
    404) die "$(api_error NOT_FOUND)
     No alert with that customId for $phone on this account." 2 ;;
    *)   die "$(api_error "HTTP $STATUS")" 2 ;;
  esac

  # NEVER test truthiness of "decision" alone — a Reject is a decision, and it
  # is truthy. Compare the label.
  if printf '%s' "$BODY" | grep -q '"decision":null'; then
    printf 'No decision yet.\n'
    return 0
  fi
  local label
  label=$(printf '%s' "$BODY" | sed -n 's/.*"decision":{[^}]*"label":"\([^"]*\)".*/\1/p')
  printf 'Decision: %s\n' "${label:-unknown}"
}

cmd_close_person() {
  local phone="" custom_id="" alert_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --phone)     phone="${2:-}"; shift 2 ;;
      --custom-id) custom_id="${2:-}"; shift 2 ;;
      --alert-id)  alert_id="${2:-}"; shift 2 ;;
      --api-key)   API_KEY="${2:-}"; shift 2 ;;
      --api)       API_HOST="${2:-}"; shift 2 ;;
      *) die "unknown option for close-person: $1" 1 ;;
    esac
  done

  require_api_key
  [ -n "$phone" ] || die "--phone is required." 1
  [ -n "$custom_id" ] || [ -n "$alert_id" ] || \
    die "close-person needs --custom-id or --alert-id." 1

  local body
  if [ -n "$custom_id" ]; then
    body="{\"phone\":\"$(json_escape "$phone")\",\"customId\":\"$(json_escape "$custom_id")\"}"
  else
    body="{\"phone\":\"$(json_escape "$phone")\",\"alertId\":\"$(json_escape "$alert_id")\"}"
  fi

  AUTH_HEADER="Authorization: Bearer $API_KEY" call POST "$API_HOST/api/v1/alerts/close" "$body"

  case "$STATUS" in
    200) printf 'Closed.\n' ;;
    404|403) printf 'Nothing to close.\n' ;;
    401) die "$(api_error UNAUTHORIZED)
     The key is wrong or was revoked. Mint a new one from the app." 2 ;;
    *)   die "$(api_error "HTTP $STATUS")" 2 ;;
  esac
}

# ── entry ───────────────────────────────────────────────────────────────────

[ $# -gt 0 ] || usage 1
case "$1" in
  check)        shift; [ "${1:-}" = "--link" ] && { LINK="${2:-}"; shift 2; }; cmd_check "$@" ;;
  send)         shift; cmd_send "$@" ;;
  close)        shift; cmd_close "$@" ;;
  invite)       shift; cmd_invite "$@" ;;
  remove)       shift; cmd_remove "$@" ;;
  alert)        shift; cmd_alert "$@" ;;
  decision)     shift; cmd_decision "$@" ;;
  close-person) shift; cmd_close_person "$@" ;;
  -h|--help|help) usage 0 ;;
  --version) printf 'm91.sh %s\n' "$VERSION" ;;
  *) die "unknown command: $1 (expected check, send, close, invite, remove, alert, decision or close-person)" 1 ;;
esac
