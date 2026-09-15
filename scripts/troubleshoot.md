# M91 Alerting — Troubleshooting

Consult this when a send fails, or when it succeeds and nobody was reached.

Covers the send link specifically. For the full API, the platform's real
constraints, and worked integrations, see
<https://siren-backend-1091285226236.asia-south1.run.app/llms.txt>.

## Script exit codes

`scripts/m91.sh` exits with the reason, so branch on the code rather than
scraping the message.

| Exit | Meaning | What to do |
|---|---|---|
| `0` | Raised and delivered, or there was nothing to close | Report success |
| `1` | Usage or configuration — no link, bad arguments, title too short | Fix the call; nothing reached the API |
| `2` | The API rejected it | Look up the `code` below |
| `3` | Raised, but **delivered to nobody** | Not a success — see *Nobody was reached* |

## API error codes

Every non-2xx response carries a machine-readable `code` alongside a
human-readable `message`. **Branch on `code`** — the message is written for a
person and can change.

| `code` | HTTP | Meaning | Fix |
|---|---|---|---|
| `UNAUTHORIZED` | 401 | The token in the link is wrong or was revoked | Copy the link again from the app. Most often this is a link rebuilt from a base URL plus a token, or one with a trailing slash — paste it whole |
| `VALIDATION_ERROR` | 400 | The payload broke a rule; the message names the field | See the validation table below |
| `CHANNEL_EMPTY` | 409 | The link works; nobody in the channel can receive an alert | Members must **accept** their invite and install M91. An invite is not membership |
| `RATE_LIMITED` | 429 | More than 60 alerts in a minute on this link | Honour `Retry-After`, then fix the cause: a repeating condition needs a `--custom-id`, not a retry loop |
| `NOT_FOUND` | 404 | On close: no such open alert | **Normal.** Treat as success |
| `FORBIDDEN` | 403 | On close: it was already resolved | **Normal.** Treat as success |
| `MALFORMED_JSON` | 400 | The body is not valid JSON | Usually shell quoting — an apostrophe inside a single-quoted `-d`. Use the script, or `-d @file.json` |
| `PAYLOAD_TOO_LARGE` | 413 | Body over 1MB | `description` caps at 2000 characters anyway. Send a summary and a reference, not a stack trace |

## Validation failures (400)

The message names the field. Common ones:

| Message contains | Cause | Fix |
|---|---|---|
| `title is required` | No `title` (or its alias `summary`) | It is the one always-required field |
| `title must be at least 5 characters` | Too short | `err`, `fail`, `down` say nothing on a locked screen |
| `Unknown field:` / `Unknown fields:` | A field outside the contract | Usually a typo (`titel`, `serverity`) or a field from another alerting product (`priority`, `tags`, `assignee`). The schema is strict on purpose — a silently dropped key is how an alert goes out blank. **There is no recipient field**: the channel is the recipient list |
| `severity must be one of: LOW, MEDIUM, HIGH, CRITICAL` | Lowercase, abbreviated, or borrowed (`P1`, `warning`, `sev1`) | Uppercase, one of the four — or omit it for `MEDIUM` |
| `must be SHARED or PERSONAL` | An `effect` outside those two literals | Uppercase exactly, or omit — it defaults to `SHARED` |
| `must be 24 characters or fewer` | A response label too long | It has to read as a button at 3am |
| `cannot repeat the same label twice` | Two labels differing only by case | Make them distinct |
| `cannot offer more than 20 options` | Too many on a POST (6 on the link form) | More than two or three is a design problem, not a limit problem |
| `send either customId or alertId` | Close named neither | Pass the id your system knows |

## Nobody was reached

A `2xx` is not proof anybody was woken. `delivered` is the field that answers
it, and the script exits `3` when it is zero.

| Symptom | Cause | Fix |
|---|---|---|
| `409 CHANNEL_EMPTY` | Nobody has accepted their invite | They must accept in the app. **The most common cause by far** |
| `delivered: 0`, no `deduplicated` | No recipient has a registered device | Check invites accepted, app installed and signed in |
| `unregistered` not empty | Accepted the channel but has no M91 account | They must install M91 and sign in with the invited number |
| `delivered` below the member count | Some were invited but never accepted | Compare against the member count in the app's channel header |
| Delivered, but the phone stayed silent | Notification permission denied for M91 on that device | Enable it in the phone's system settings. Delivery counts at hand-off, not at the sound |

## Suppressed on purpose (not failures)

| Symptom | Cause | What to do |
|---|---|---|
| `deduplicated: true`, "is already open" | That `customId` has an open alert. Re-notifying an unanswered alert is an escalation policy, not a side effect of dedup | Nothing, if it is the same problem. Close the first to let the next one through |
| `deduplicated: true`, "sent seconds ago" | Byte-identical payload from one link within 5 seconds — an idempotency guard so a timed-out retry does not double-alert | Nothing for a machine. Testing by hand, change any field |
| A bare link returns `ok: true` and nothing happens | A `GET` with no `title` is the connection test, by design — it is what stops link previews and crawlers waking a team | Add `?title=...` to raise one. Never ask for a default title |
| A link opened in a browser returns a web page | The route returns HTML to a caller sending `Accept: text/html`, because this URL is built to be opened by people | Nothing. Scripts get JSON automatically |
| Repeats stopped arriving entirely | An alert was opened with a `customId` and never closed. While open, every repeat is absorbed — silently, since the sends still return `200` | Close it. Every `custom-id` you open needs a path that closes it |

## Behaviour that looks like a bug

| Symptom | Why |
|---|---|
| A `SHARED` response did not close the alert | By design — `isAutoClose` defaults to `false`. A `SHARED` response stands the other phones down; it does not end the alert. Pass `--auto-close` for fire-and-forget |
| An alert with no response options never closes | Nothing can settle it. For a pure notice, send empty response options **together with** auto-close |
| Somebody wants to change their answer | One response per person, final. A `SHARED` response can never be superseded — the alert has an owner from that moment |
| No phone call on an unanswered alert | Only `HIGH` and `CRITICAL` dial, 45s after no response. `LOW`/`MEDIUM` interrupt every phone but never call. Omitting severity gives `MEDIUM` |
| The alert reached the wrong people | The link belongs to a different channel than assumed. Run `./scripts/m91.sh check` and read the channel name |

## Cannot reach M91 at all

A connection or DNS-level failure — not an HTTP error response — usually means
a network-sandboxed agent environment with a fixed outbound-domain allowlist.

1. If you can change that setting, add the M91 host to it.
2. If you cannot (most agents cannot — it is usually an org-admin decision),
   tell the person the exact host to add rather than reporting "alert failed".
3. Either way, mention that the same command works unchanged from a local
   terminal or any environment with normal network access.

Do not confuse this with a `4xx`/`5xx`, which is a normal API error covered
above.
