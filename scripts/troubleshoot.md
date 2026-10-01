# M91 Troubleshooting

<!-- GENERATED from siren-backend/src/public-docs/troubleshoot.md.
     Edit that file and run `npm run sync-skill`; edits here are overwritten. -->

Real failures the API returns — not hypotheticals. Each entry is the same
shape:

- **Match** — the exact substring to look for in a response body.
- **Cause** — what went wrong, in one clause.
- **Why** — the reasoning behind the behaviour, where there is any. Several
  entries here describe deliberate design that looks like a bug; this line is
  what tells them apart.
- **Fix** — what to do.

Grouped by where in the lifecycle it went wrong: did the request arrive, was it
rejected before an alert existed, was the alert raised but nobody reached, was it
a repeat, did closing fail. Covers both the send link and the API key. See
[`api.md`](https://m91.msg91.com/api/public/api.md) for the reference this guide assumes,
and
[`limitations-and-recommendations.md`](https://m91.msg91.com/api/public/limitations-and-recommendations.md)
for what M91 does and does not guarantee — *before* you hit it, not after.

Every error body is
`{"success": false, "error": {"code": "...", "message": "...", "details": {...}, "docs": "..."}}`.

**Branch on `code`.** The `message` is written for a person to read and can
change; validation messages in particular are assembled per field.

**`docs` is a link straight to the entry below for that code.** Follow it rather
than searching — it is there so a failure in your own logs carries its own
explanation.

## Before anything else: did the request reach M91?

### The call never completes — connection refused, DNS failure, or a hang
- no response body at all
- **Cause** — no network route to `m91.msg91.com` from where the code is running.
  Common in CI, in a container with egress rules, and in agent sandboxes.
- **Why** — every other entry in this file assumes a response. If there is no
  response, nothing below applies and no amount of payload fixing will help.
- **Fix** — test the host itself, not the API: `curl -sS -o /dev/null -w '%{http_code}'
  https://m91.msg91.com/api/public/index.md` should print `200`. If it does not,
  the problem is egress, not M91. **If you are an agent in a sandbox: say you
  could not verify.** Write the integration, leave the link in configuration, and
  give the person the exact command to run. Never report alerting as working when
  you have not seen it work.

### MALFORMED_JSON from PowerShell, with a payload that is definitely valid
- `match`: `"MALFORMED_JSON"` after a `curl.exe` call from PowerShell
- **Cause** — PowerShell's argument handling, not your payload. It rewrites the
  quoting on the way to `curl.exe` and M91 receives something that is not JSON.
- **Why** — the same error code is raised by genuine quoting mistakes in the
  body, so this reads as a payload bug and is not one.
- **Fix** — use `Invoke-RestMethod` with `ConvertTo-Json` rather than `curl.exe`.
  See [the quickstart](https://m91.msg91.com/api/public/quickstart.md#no-bash).

## The link itself

### 401 UNAUTHORIZED
- **Match** — `"code":"UNAUTHORIZED"`, `"Invalid sender token"`
- **Cause** — the token in the path is wrong, was revoked, or the URL was assembled from parts rather than pasted whole.
- **Why** — A trailing slash, a URL-encoded segment, a truncated copy, or a base URL and token joined in code all produce this
- **Fix** — copy the link again from the M91 app (channel → paper-plane icon → **Send alert link**) and use it verbatim as one opaque string. Verify with a bare `GET`, which alerts nobody and names the channel. Revoked links are not recoverable — there is no rotation, so a revoked link is replaced by a new one

### A bare GET returns `ok: true` but nothing happens
- **Match** — `{"success":true,"data":{"ok":true,"channel":{...}}}`
- **Cause** — **not a failure.** A `GET` with no `title` is the connection test and deliberately raises nothing.
- **Why** — That is what stops link previews, chat unfurls, mail scanners and crawlers from waking a team when the URL is pasted somewhere
- **Fix** — add `?title=...` to raise a real alert. Never expect a bare link to alert, and never ask for a default title — see [`title`](https://m91.msg91.com/api/public/fields.md#title)

### A link opened in a browser returns a web page instead of JSON
- **Match** — `Content-Type: text/html` on a `GET .../s/<token>?title=...`
- **Cause** — **not a failure.** The route returns HTML when the caller sends `Accept: text/html`, because this URL is built to be opened by people from a bookmark or a shortcut, and ending that in raw JSON tells them nothing
- **Fix** — nothing to fix if a person opened it. A script gets JSON automatically since it sends no `Accept: text/html`; `curl` already behaves this way. Force it with `-H 'Accept: application/json'` if some client sends an HTML-accepting header

## Rejected before an alert is raised

### 400 VALIDATION_ERROR — title missing
- **Match** — `"title is required"`
- **Cause** — no `title` (or its alias `summary`) in the body, or no `title=` in the query string. It is the one always-required field
- **Fix** — send a `title`. On the link form it is required by design and has no default — see the security note in [`title`](https://m91.msg91.com/api/public/fields.md#title)

### 400 VALIDATION_ERROR — title too short or too long
- **Match** — `"title must be at least 5 characters"`, `"title must be 2000 characters or fewer"`
- **Cause** — `title` outside 5–2000 characters after surrounding whitespace is collapsed. A 5-character floor rules out `err`, `fail`, `down` and similar, which say nothing on a locked screen
- **Fix** — write a title that names what happened and where. Put detail in `description` (also capped at 2000)

### 400 VALIDATION_ERROR — unknown field
- **Match** — `"Unknown field: "`, `"Unknown fields: "`, `". Check the spelling."`
- **Cause** — a field that is not part of the contract.
- **Why** — Usually a typo (`titel`, `serverity`, `custom_id`), a field from some other alerting product (`priority`, `source`, `tags`, `assignee`), or recipients passed in the payload. The schema is strict on purpose: silently dropping an unknown key is how an alert goes out with no title
- **Fix** — the named key is in the message. Use only the documented fields — see [Alert fields](https://m91.msg91.com/api/public/api.md#post). There is no recipient field at all: the channel *is* the recipient list

### 400 VALIDATION_ERROR — bad severity
- **Match** — `"severity must be one of: LOW, MEDIUM, HIGH, CRITICAL"`
- **Cause** — a severity that is lowercase, abbreviated, numeric, or borrowed from another tool (`P1`, `warning`, `error`, `sev1`, `urgent`)
- **Fix** — send one of the four exactly, uppercase — or omit it entirely, which gives `MEDIUM`

### 400 VALIDATION_ERROR — bad response effect
- **Match** — `"must be SHARED or PERSONAL"`
- **Cause** — an `effect` other than those two literals, usually lowercase or a synonym (`shared`, `ack`, `acknowledge`, `claim`)
- **Fix** — uppercase `SHARED` or `PERSONAL` exactly, or omit `effect` — it defaults to `SHARED`. They mean responsibility, not mechanism: see [Responses](https://m91.msg91.com/api/public/fields.md#responses)

### 400 VALIDATION_ERROR — response option problems
- **Match** — `"must be 24 characters or fewer"`, `"cannot repeat the same label twice"`, `"cannot offer more than 20 options"`, `"cannot offer more than 6 options in a link"`
- **Cause** — a label longer than 24 characters (it has to be readable as a button at 3am), two labels that differ only by case, more than 20 options on a `POST`, or more than 6 on the `?respond=` link form
- **Fix** — shorten the labels, make them distinct, and cut the list. More than two or three choices on an alert is almost always a design problem rather than a limit problem — the person reading it is half-awake

### 400 VALIDATION_ERROR — isAutoClose not a boolean
- **Match** — `"isAutoClose must be true or false"`
- **Cause** — on the `POST`, a string `"true"` instead of a real JSON boolean. On the link form, a value outside the accepted spellings
- **Fix** — send a JSON boolean on the `POST`. The link form accepts `true`/`false`/`1`/`0`/`yes`/`no`/`on`/`off`

### 400 MALFORMED_JSON
- **Match** — `"code":"MALFORMED_JSON"`, `"Request body is not valid JSON"`
- **Cause** — the body is not valid JSON.
- **Why** — Most often a shell-quoting problem in a `curl -d '...'` where the payload contains a quote or an apostrophe
- **Fix** — quote the payload properly, or build it from a file with `-d @payload.json`. Apostrophes inside a single-quoted shell string are the usual culprit

### The request seems to send nothing, or title comes back missing
- no `match` — the request fails validation as though the body were empty
- **Cause** — `Content-Type: application/json` was omitted on a `POST`. `curl -d` defaults to form encoding and the server parses JSON only, so the body arrives empty
- **Fix** — add `-H 'Content-Type: application/json'`. It is required, not decoration

### 413 PAYLOAD_TOO_LARGE
- **Match** — `"code":"PAYLOAD_TOO_LARGE"`
- **Cause** — the request body exceeds the 1MB limit.
- **Why** — Usually a stack trace or a log dump pasted into `description`
- **Fix** — `description` is capped at 2000 characters anyway. Send a summary and a reference (an id, a URL) that points at the full detail in your own system

## Nobody was reached

### 409 CHANNEL_EMPTY
- **Match** — `"code":"CHANNEL_EMPTY"`, `"Nobody has joined this channel yet"`, `"have not installed M91 yet"`
- **Cause** — the link and the request are both fine.
- **Why** — The channel has nobody who can receive an alert. Either nobody has accepted their invite, or the people who accepted have not installed M91 and signed in. `details.unregistered` lists the second group
- **Fix** — people must **accept** the invite in the app and have M91 installed. An invite is an offer, not membership. This is the most common reason a correct integration reaches nobody, and it is worth checking before debugging anything else

### delivered: 0 on a 201
- **Match** — `"delivered":0` alongside `"success":true`
- **Cause** — the alert was created and nothing was sent to anybody. Either no recipient has a device registered.
- **Why** — Check `unregistered` and `noDevice`, which say which kind — or this was a deduplicated send, in which case `"deduplicated":true` is also present and nobody needed alerting again
- **Fix** — assert on `delivered`, not on the status code, and check `deduplicated` first so a suppressed repeat is not read as a failure. If `deduplicated` is absent, the roster is the problem: invites accepted, app installed, signed in, and opened at least once on each phone

### unregistered is not empty
- **Match** — `"unregistered":["..."]`
- **Cause** — those people accepted the channel invite but never signed in, so they have no M91 account and there is nothing to deliver to. They are counted as members and reached by nothing
- **Fix** — they must install M91 and sign in with the number that was invited

### noDevice is not zero
- **Match** — `"noDevice":1` or higher in the send response
- **Cause** — those people accepted **and** signed in, but have no device registered, so nothing was sent to them. Most often the app was reinstalled or restored and has not been opened since; the app registers its device token on every launch, so it has had no chance to
- **Fix** — they open the M91 app once. It registers on launch, and every alert after that reaches them. From the channel screen they look like ordinary members, which is why this is reported separately

### Sent, reported delivered, and the phone still stayed silent
- no `match` — a normal `201` with a non-zero `delivered`
- **Cause** — `delivered` counts recipients the alert was **dispatched to**, not confirmations that a phone made a sound. The push can still be dropped after that: notification permission denied for M91 on that device, or a device token the platform has invalidated since it was registered.
- **Why** — The push service accepts a dead token and reports success, so nothing fails anywhere
- **Fix** — check notification permission for M91 on that phone, and have them open the app once to re-register the device. The only positive proof somebody saw an alert is a response coming back

### Fewer delivered than the channel has members
- no `match` — a normal `201` with a low `delivered`
- **Cause** — some members are still invited rather than accepted, or accepted without installing
- **Fix** — compare `delivered` against the member count in the app's channel header. The gap is the number of people who have not finished joining

## Repeats and duplicates

### deduplicated: true — an open customId
- **Match** — `"deduplicated":true`, `"is already open, so nobody was alerted again"`
- **Cause** — **working as intended.** An alert with that `customId` is still open on this channel, so the same alert was returned and nobody was alerted a second time. Re-notifying an unanswered alert is an escalation policy, not a side effect of deduplication
- **Fix** — nothing, if the problem is genuinely the same one. If repeats *should* raise fresh alerts, close the previous one first — closing is what lets the next occurrence through. If they are genuinely different problems, give them different `customId`s

### deduplicated: true — an identical payload within 5 seconds
- **Match** — `"deduplicated":true`, `"An identical alert was sent seconds ago"`
- **Cause** — **working as intended.** Byte-identical payloads from one link inside a 5-second window collapse into one alert. This is an idempotency guard so a client that times out and retries does not raise two
- **Fix** — nothing for a machine. If you are testing by hand and want each run to land, change any field — a timestamp in the `title` or `description` is enough

### 429 RATE_LIMITED
- **Match** — `"code":"RATE_LIMITED"`, `"which is its limit"`
- **Cause** — more than 60 alerts in a minute on one link. Almost always a condition that keeps firing with no `customId`, or a retry loop with no backoff
- **Fix** — honour the `Retry-After` header. Then fix the cause: add a `customId` so repeats collapse into one alert, and close it when the condition clears. See [Repeating problems](https://m91.msg91.com/api/public/api.md#repeats)

## Closing an alert

### 404 NOT_FOUND on close
- **Match** — `"code":"NOT_FOUND"`, `"alert_not_found"`
- **Cause** — **normal on a healthy run.** No alert with that `customId` exists on this channel.
- **Why** — Usually because the condition never went bad, or the alert was already closed by a person in the app
- **Fix** — treat `404` on close as success. Code that logs it as an error will log one on every healthy check

### 403 FORBIDDEN on close
- **Match** — `"code":"FORBIDDEN"`
- **Cause** — **normal.** The alert exists but could not be closed, in practice because it was already resolved
- **Fix** — treat `403` on close as success too. `404` and `403` both mean "there was nothing to close"

### 400 VALIDATION_ERROR on close — nothing named
- **Match** — `"send either customId or alertId to say which alert to close"`
- **Cause** — the close body named neither
- **Fix** — send `{"customId": "..."}` — the id your own system knows — or `{"alertId": "..."}` from the `_id` of a create response

### A higher severity on the same customId changed nothing
- no `match` — the send returns `200` with `"deduplicated":true`
- **Cause** — while an alert is open, a repeat of its `customId` is **inert**.
- **Why** — The payload is discarded entirely, not just the notification. The title, description and severity you sent are ignored and the alert keeps what it was created with, so a condition that worsened cannot escalate itself this way
- **Fix** — an alert that must interrupt people again is a different alert. Use a separate `customId` for the worse condition, or close the first so the next send raises fresh. See [The lifecycle](https://m91.msg91.com/api/public/api.md#repeats)

### Responses vanished after an alert came back
- no `match` — the alert is open again with nobody shown as having answered
- **Cause** — **by design.** Reopening a closed `customId` reuses the same alert record, and every previous response is voided.
- **Why** — The roster is rebuilt and whoever took it last time no longer owns it. A reopen is a fresh occurrence of the same problem, so an answer about last time cannot stand in for this time
- **Fix** — nothing. If you need the history, it is in the alert's activity log, which records each `REOPENED` along with the count

### Every repeat raised a new alert and flooded the channel
- no `match` — many near-identical alerts, then `429 RATE_LIMITED`
- **Cause** — the `customId` is unique per occurrence rather than per condition.
- **Why** — It contains a timestamp, run id, UUID or retry counter. That deduplicates nothing while looking like it does
- **Fix** — the id must be the **same string every time the same condition is detected** — `nightly-export`, not `nightly-export-2026-09-15T02:00`. Where identity is genuinely per-thing, put the thing in it and keep it stable: `disk-full-node7`

### Repeats stopped arriving entirely
- no `match` — sends return `200` with `"deduplicated":true` forever
- **Cause** — an alert was opened with a `customId` and never closed. While it is open, every repeat of that id is absorbed
- **Fix** — close it, by `customId` from your own code or by a person in the app. Then design the close in: every `customId` you open needs a path that closes it when the condition clears

## Reading back a decision

### 404 NOT_FOUND on GET .../alerts/...
- **Match** — `"code":"NOT_FOUND"`, `"alert_not_found"` from `GET <SEND_LINK>/alerts/...`
- **Cause** — no alert with that `customId` or `_id` **on this channel**. Either it was never raised, the id is misspelled, or the link belongs to a different channel than the one the alert went to
- **Fix** — check the id against what you sent, and bare-`GET` the link to confirm the channel. Unlike close, a `404` here is not routine — it means you are polling for something that does not exist

### decision stays null forever
- no `match` — `"decision":null` on every poll
- **Cause** — nobody has given a **SHARED** response. Either no one has answered at all, or every answer so far was `PERSONAL`.
- **Why** — Those are acknowledgements and never become a decision
- **Fix** — if you need an answer, the options must include at least one `SHARED`; two `SHARED` options is how you ask a question with two answers. And set your own timeout — M91 keeps an alert open until somebody closes it, so an agent waiting on `decision` waits forever by default

### A response came back but decision is still null
- no `match` — `responses` has entries, `decision` is `null`
- **Cause** — **by design.** Only a `SHARED` response decides. A `PERSONAL` response records that one person is aware and changes nothing for anybody else; surfacing it as a decision would let an agent read "Seen" as "Approved"
- **Fix** — read `decision` for the answer and `responses` for the full picture. If those options were meant as answers, give them `effect: "SHARED"`

### Polling gets 429 RATE_LIMITED
- **Match** — `"code":"RATE_LIMITED"` on `GET <SEND_LINK>/alerts/...`
- **Cause** — not something the status read produces today: it carries no rate limit, while the 60-a-minute limit is checked only when an alert is RAISED. A `429` here means the limit was added after this was written
- **Why** — this entry used to claim polls shared the send budget. They do not — `canSendNow` is called in `raiseAlert` alone — and an agent told to poll slowly for a reason that was not true would have trusted the rest of this file less
- **Fix** — poll every few seconds anyway. A person is deciding; sub-second polling buys nothing, and an unmetered endpoint is one nobody has needed to meter yet

## The API key flow

Everything above is the send link. These are the failures specific to
`Authorization: Bearer m91sk_…` — inviting a person, creating a channel, and
alerting somebody directly.

### `state` is null on an invite that clearly worked
- `match`: a successful `POST /api/v1/recipients` whose `state` reads as missing
- **Cause** — reading `state` from the top level of the response. It is inside
  `data`, like every other field of every other M91 response.
- **Why** — the envelope is uniform:
  `{ "success": true, "data": { "phone", "state", "reachable" } }`. A top-level
  read returns `undefined` rather than throwing, so the call looks like it
  succeeded and returned nothing — which is exactly what it did.
- **Fix** — read `body.data.state`. The full shape of every endpoint is in
  [api.md](https://m91.msg91.com/api/public/api.md#responses).

### 401 UNAUTHORIZED on every API-key call
- `match`: `"UNAUTHORIZED"`
- **Cause** — the key is missing, revoked, or sent without the `Bearer ` prefix.
- **Fix** — `Authorization: Bearer m91sk_…`, with the space. Check
  `GET /api/v1/me` first: it is the cheapest call that proves the key works and
  returns the key's label and owner.

### 404 not_a_recipient when alerting a phone number
- `match`: `"not_a_recipient"`
- **Cause** — that phone number was never invited through `POST /api/v1/recipients`,
  or was invited and has not accepted yet.
- **Why** — an alert must never be what invites somebody. An invited person is
  not an M91 user yet, so the urgent thing would arrive as an ordinary message
  that does not pierce Do Not Disturb, does not repeat and does not escalate.
  Failing loudly is better than delivering something that cannot wake anybody.
- **Fix** — invite, then wait for them to accept. **This is the step most
  integrations forget.** `reachable: false` on the invite response means they
  have not accepted; poll `GET /api/v1/recipients` or just handle the 404.

### reachable: false and it never becomes true
- `match`: `"reachable": false`
- **Cause** — the person has not accepted the invitation in the M91 app.
- **Why** — consent. There is no way around it and no API that bypasses it.
- **Fix** — nothing in code. The person must install M91 and accept. Surface
  this in your own UI rather than retrying.

### A channel created by API key cannot be alerted by API key
- `match`: a 4xx on alerting a channel you just created
- **Cause** — an API key provisions channels and alerts individuals. Alerting a
  whole channel is the send link's job.
- **Fix** — `POST /api/v1/channels` returns the channel's `sendLink`. Store it
  and use that to alert the channel.

### Closing an alert raised for a person
- `match`: `"NOT_FOUND"` on `POST /api/v1/alerts/close`
- **Cause** — closing by `customId` without naming the same recipient the alert
  was raised for, or the alert is already closed.
- **Fix** — pass the same `customId` and phone number used to raise it. An
  already-closed alert is not an error worth retrying.

## Behaviour that looks like a bug and is not

### A SHARED response did not close the alert
- no `match` — the alert stays `OPEN` after somebody responds
- **Cause** — **by design.** `isAutoClose` defaults to `false`. A `SHARED` response stands every other phone down immediately, but it does not end the alert: closing says the thing is *over*, and usually only a person can say that. Auto-closing removes the alert from everyone's screen before anybody can see who took it or what came of it
- **Fix** — nothing, if you want a record somebody can act on and close. Send `isAutoClose: true` for genuine fire-and-forget. See [When an alert ends](https://m91.msg91.com/api/public/api.md#ends)

### An alert with no response options never closes
- no `match` — the alert sits `OPEN` indefinitely
- **Cause** — nothing can settle it. With no options there is no response to give, and with `isAutoClose` defaulting to `false` nothing closes it automatically
- **Fix** — for a pure notice, send an explicit empty `responseOptions: []` **together with** `isAutoClose: true` — that pair means "nothing to answer, nothing to follow up", and it closes on delivery. Otherwise close it from your own code, or offer a response somebody can give

### Somebody wants to change their answer
- no `match` — there is no endpoint for it
- **Cause** — **by design.** One response per person, and it is final. A `SHARED` response can never be superseded.
- **Why** — Somebody has taken responsibility, and the alert has an owner from that moment
- **Fix** — nothing to fix. If the situation changed, that is a new alert, or a comment from the person in the app

### No phone call on an unanswered alert
- no `match`
- **Cause** — one of five, in the order worth checking. (1) The alert was `LOW` or `MEDIUM`, which interrupt every phone but never dial. (2) It was `HIGH` and the channel was not dark — `HIGH` calls only when nobody has responded *and* nobody has opened the alert in the last few minutes, so a team already looking at it is never phoned. (3) Somebody responded, which stops the chain immediately. (4) That person opened the alert, which takes them out of the call list, or was called for anything in the last 10 minutes. (5) The channel's hourly call quota is spent
- **Fix** — use `CRITICAL` when a call is genuinely warranted regardless of who is watching; use `HIGH` when a call is the right answer only if the team has gone quiet. Omitting `severity` gives `MEDIUM`, which does not dial — that default is deliberate

### The alert went to the wrong people
- no `match` — it delivers successfully to a channel you did not mean
- **Cause** — the link belongs to a different channel than you thought. Most likely once an account has several
- **Fix** — bare-`GET` the link and read `data.channel.name` before wiring it in. Keep one link per channel per integration, and name the sender when you create it so the app shows which integration filed each alert
