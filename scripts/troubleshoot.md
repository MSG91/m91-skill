# M91 Troubleshooting

<!-- GENERATED from siren-backend/src/public-docs/troubleshoot.md.
     Edit that file and run `npm run sync-skill`; edits here are overwritten. -->

Real failures the API returns — not hypotheticals. Each entry: `match` (exact
substring to look for in a response body) → `cause` → `fix`.

Covers the whole integration surface: checking a link, raising an alert by link
or by JSON, and closing one. See
[`docs.md`](https://m91.msg91.com/api/public/docs.md) for the API reference this
guide assumes, and
[`limitations-and-recommendations.md`](https://m91.msg91.com/api/public/limitations-and-recommendations.md)
for what M91 does and does not guarantee — *before* you hit it, not after.

Every error body is
`{"success": false, "error": {"code": "...", "message": "...", "details": {...}}}`.
**Branch on `code`.** The `message` is written for a person to read and can
change; validation messages in particular are assembled per field.

## The link itself

### 401 UNAUTHORIZED
- match: `"code":"UNAUTHORIZED"`, `"Invalid sender token"`
- cause: the token in the path is wrong, was revoked, or the URL was assembled from parts rather than pasted whole — a trailing slash, a URL-encoded segment, a truncated copy, or a base URL and token joined in code all produce this
- fix: copy the link again from the M91 app (channel → paper-plane icon → **Send alert link**) and use it verbatim as one opaque string. Verify with a bare `GET`, which alerts nobody and names the channel. Revoked links are not recoverable — there is no rotation, so a revoked link is replaced by a new one

### A bare GET returns `ok: true` but nothing happens
- match: `{"success":true,"data":{"ok":true,"channel":{...}}}`
- cause: **not a failure.** A `GET` with no `title` is the connection test and deliberately raises nothing — that is what stops link previews, chat unfurls, mail scanners and crawlers from waking a team when the URL is pasted somewhere
- fix: add `?title=...` to raise a real alert. Never expect a bare link to alert, and never ask for a default title — see [The send link](https://m91.msg91.com/api/public/docs.md#send-link)

### A link opened in a browser returns a web page instead of JSON
- match: `Content-Type: text/html` on a `GET .../s/<token>?title=...`
- cause: **not a failure.** The route returns HTML when the caller sends `Accept: text/html`, because this URL is built to be opened by people from a bookmark or a shortcut, and ending that in raw JSON tells them nothing
- fix: nothing to fix if a person opened it. A script gets JSON automatically since it sends no `Accept: text/html`; `curl` already behaves this way. Force it with `-H 'Accept: application/json'` if some client sends an HTML-accepting header

## Rejected before an alert is raised

### 400 VALIDATION_ERROR — title missing
- match: `"title is required"`
- cause: no `title` (or its alias `summary`) in the body, or no `title=` in the query string. It is the one always-required field
- fix: send a `title`. On the link form it is required by design and has no default — see the security note in [`docs.md`](https://m91.msg91.com/api/public/docs.md#send-link)

### 400 VALIDATION_ERROR — title too short or too long
- match: `"title must be at least 5 characters"`, `"title must be 2000 characters or fewer"`
- cause: `title` outside 5–2000 characters after surrounding whitespace is collapsed. A 5-character floor rules out `err`, `fail`, `down` and similar, which say nothing on a locked screen
- fix: write a title that names what happened and where. Put detail in `description` (also capped at 2000)

### 400 VALIDATION_ERROR — unknown field
- match: `"Unknown field: "`, `"Unknown fields: "`, `". Check the spelling."`
- cause: a field that is not part of the contract — usually a typo (`titel`, `serverity`, `custom_id`), a field from some other alerting product (`priority`, `source`, `tags`, `assignee`), or recipients passed in the payload. The schema is strict on purpose: silently dropping an unknown key is how an alert goes out with no title
- fix: the named key is in the message. Use only the documented fields — see [Alert fields](https://m91.msg91.com/api/public/docs.md#alert-fields). There is no recipient field at all: the channel *is* the recipient list

### 400 VALIDATION_ERROR — bad severity
- match: `"severity must be one of: LOW, MEDIUM, HIGH, CRITICAL"`
- cause: a severity that is lowercase, abbreviated, numeric, or borrowed from another tool (`P1`, `warning`, `error`, `sev1`, `urgent`)
- fix: send one of the four exactly, uppercase — or omit it entirely, which gives `MEDIUM`

### 400 VALIDATION_ERROR — bad response effect
- match: `"must be SHARED or PERSONAL"`
- cause: an `effect` other than those two literals, usually lowercase or a synonym (`shared`, `ack`, `acknowledge`, `claim`)
- fix: uppercase `SHARED` or `PERSONAL` exactly, or omit `effect` — it defaults to `SHARED`. They mean responsibility, not mechanism: see [Responses](https://m91.msg91.com/api/public/docs.md#responses)

### 400 VALIDATION_ERROR — response option problems
- match: `"must be 24 characters or fewer"`, `"cannot repeat the same label twice"`, `"cannot offer more than 20 options"`, `"cannot offer more than 6 options in a link"`
- cause: a label longer than 24 characters (it has to be readable as a button at 3am), two labels that differ only by case, more than 20 options on a `POST`, or more than 6 on the `?respond=` link form
- fix: shorten the labels, make them distinct, and cut the list. More than two or three choices on an alert is almost always a design problem rather than a limit problem — the person reading it is half-awake

### 400 VALIDATION_ERROR — isAutoClose not a boolean
- match: `"isAutoClose must be true or false"`
- cause: on the `POST`, a string `"true"` instead of a real JSON boolean. On the link form, a value outside the accepted spellings
- fix: send a JSON boolean on the `POST`. The link form accepts `true`/`false`/`1`/`0`/`yes`/`no`/`on`/`off`

### 400 MALFORMED_JSON
- match: `"code":"MALFORMED_JSON"`, `"Request body is not valid JSON"`
- cause: the body is not valid JSON — most often a shell-quoting problem in a `curl -d '...'` where the payload contains a quote or an apostrophe
- fix: quote the payload properly, or build it from a file with `-d @payload.json`. Apostrophes inside a single-quoted shell string are the usual culprit

### The request seems to send nothing, or title comes back missing
- no `match` — the request fails validation as though the body were empty
- cause: `Content-Type: application/json` was omitted on a `POST`. `curl -d` defaults to form encoding and the server parses JSON only, so the body arrives empty
- fix: add `-H 'Content-Type: application/json'`. It is required, not decoration

### 413 PAYLOAD_TOO_LARGE
- match: `"code":"PAYLOAD_TOO_LARGE"`
- cause: the request body exceeds the 1MB limit — usually a stack trace or a log dump pasted into `description`
- fix: `description` is capped at 2000 characters anyway. Send a summary and a reference (an id, a URL) that points at the full detail in your own system

## Nobody was reached

### 409 CHANNEL_EMPTY
- match: `"code":"CHANNEL_EMPTY"`, `"Nobody has joined this channel yet"`, `"have not installed M91 yet"`
- cause: the link and the request are both fine — the channel has nobody who can receive an alert. Either nobody has accepted their invite, or the people who accepted have not installed M91 and signed in. `details.unregistered` lists the second group
- fix: people must **accept** the invite in the app and have M91 installed. An invite is an offer, not membership. This is the most common reason a correct integration reaches nobody, and it is worth checking before debugging anything else

### delivered: 0 on a 201
- match: `"delivered":0` alongside `"success":true`
- cause: the alert was created and nothing was sent to anybody. Either no recipient has a device registered — check `unregistered` and `noDevice`, which say which kind — or this was a deduplicated send, in which case `"deduplicated":true` is also present and nobody needed alerting again
- fix: assert on `delivered`, not on the status code, and check `deduplicated` first so a suppressed repeat is not read as a failure. If `deduplicated` is absent, the roster is the problem: invites accepted, app installed, signed in, and opened at least once on each phone

### unregistered is not empty
- match: `"unregistered":["..."]`
- cause: those people accepted the channel invite but never signed in, so they have no M91 account and there is nothing to deliver to. They are counted as members and reached by nothing
- fix: they must install M91 and sign in with the number that was invited

### noDevice is not zero
- match: `"noDevice":1` or higher in the send response
- cause: those people accepted **and** signed in, but have no device registered, so nothing was sent to them. Most often the app was reinstalled or restored and has not been opened since; the app registers its device token on every launch, so it has had no chance to
- fix: they open the M91 app once. It registers on launch, and every alert after that reaches them. From the channel screen they look like ordinary members, which is why this is reported separately

### Sent, reported delivered, and the phone still stayed silent
- no `match` — a normal `201` with a non-zero `delivered`
- cause: `delivered` counts recipients the alert was **dispatched to**, not confirmations that a phone made a sound. The push can still be dropped after that: notification permission denied for M91 on that device, or a device token the platform has invalidated since it was registered — the push service accepts a dead token and reports success, so nothing fails anywhere
- fix: check notification permission for M91 on that phone, and have them open the app once to re-register the device. The only positive proof somebody saw an alert is a response coming back

### Fewer delivered than the channel has members
- no `match` — a normal `201` with a low `delivered`
- cause: some members are still invited rather than accepted, or accepted without installing
- fix: compare `delivered` against the member count in the app's channel header. The gap is the number of people who have not finished joining

## Repeats and duplicates

### deduplicated: true — an open customId
- match: `"deduplicated":true`, `"is already open, so nobody was alerted again"`
- cause: **working as intended.** An alert with that `customId` is still open on this channel, so the same alert was returned and nobody was alerted a second time. Re-notifying an unanswered alert is an escalation policy, not a side effect of deduplication
- fix: nothing, if the problem is genuinely the same one. If repeats *should* raise fresh alerts, close the previous one first — closing is what lets the next occurrence through. If they are genuinely different problems, give them different `customId`s

### deduplicated: true — an identical payload within 5 seconds
- match: `"deduplicated":true`, `"An identical alert was sent seconds ago"`
- cause: **working as intended.** Byte-identical payloads from one link inside a 5-second window collapse into one alert. This is an idempotency guard so a client that times out and retries does not raise two
- fix: nothing for a machine. If you are testing by hand and want each run to land, change any field — a timestamp in the `title` or `description` is enough

### 429 RATE_LIMITED
- match: `"code":"RATE_LIMITED"`, `"which is its limit"`
- cause: more than 60 alerts in a minute on one link. Almost always a condition that keeps firing with no `customId`, or a retry loop with no backoff
- fix: honour the `Retry-After` header. Then fix the cause: add a `customId` so repeats collapse into one alert, and close it when the condition clears. See [Repeating problems](https://m91.msg91.com/api/public/docs.md#repeating-problems)

## Closing an alert

### 404 NOT_FOUND on close
- match: `"code":"NOT_FOUND"`, `"alert_not_found"`
- cause: **normal on a healthy run.** No alert with that `customId` exists on this channel — usually because the condition never went bad, or the alert was already closed by a person in the app
- fix: treat `404` on close as success. Code that logs it as an error will log one on every healthy check

### 403 FORBIDDEN on close
- match: `"code":"FORBIDDEN"`
- cause: **normal.** The alert exists but could not be closed, in practice because it was already resolved
- fix: treat `403` on close as success too. `404` and `403` both mean "there was nothing to close"

### 400 VALIDATION_ERROR on close — nothing named
- match: `"send either customId or alertId to say which alert to close"`
- cause: the close body named neither
- fix: send `{"customId": "..."}` — the id your own system knows — or `{"alertId": "..."}` from the `_id` of a create response

### A higher severity on the same customId changed nothing
- no `match` — the send returns `200` with `"deduplicated":true`
- cause: while an alert is open, a repeat of its `customId` is **inert** — the payload is discarded entirely, not just the notification. The title, description and severity you sent are ignored and the alert keeps what it was created with, so a condition that worsened cannot escalate itself this way
- fix: an alert that must interrupt people again is a different alert. Use a separate `customId` for the worse condition, or close the first so the next send raises fresh. See [The lifecycle](https://m91.msg91.com/api/public/docs.md#custom-id-lifecycle)

### Responses vanished after an alert came back
- no `match` — the alert is open again with nobody shown as having answered
- cause: **by design.** Reopening a closed `customId` reuses the same alert record, and every previous response is voided — the roster is rebuilt and whoever took it last time no longer owns it. A reopen is a fresh occurrence of the same problem, so an answer about last time cannot stand in for this time
- fix: nothing. If you need the history, it is in the alert's activity log, which records each `REOPENED` along with the count

### Every repeat raised a new alert and flooded the channel
- no `match` — many near-identical alerts, then `429 RATE_LIMITED`
- cause: the `customId` is unique per occurrence rather than per condition — it contains a timestamp, run id, UUID or retry counter. That deduplicates nothing while looking like it does
- fix: the id must be the **same string every time the same condition is detected** — `nightly-export`, not `nightly-export-2026-09-15T02:00`. Where identity is genuinely per-thing, put the thing in it and keep it stable: `disk-full-node7`

### Repeats stopped arriving entirely
- no `match` — sends return `200` with `"deduplicated":true` forever
- cause: an alert was opened with a `customId` and never closed. While it is open, every repeat of that id is absorbed
- fix: close it, by `customId` from your own code or by a person in the app. Then design the close in: every `customId` you open needs a path that closes it when the condition clears

## Reading back a decision

### 404 NOT_FOUND on GET .../alerts/...
- match: `"code":"NOT_FOUND"`, `"alert_not_found"` from `GET <SEND_LINK>/alerts/...`
- cause: no alert with that `customId` or `_id` **on this channel**. Either it was never raised, the id is misspelled, or the link belongs to a different channel than the one the alert went to
- fix: check the id against what you sent, and bare-`GET` the link to confirm the channel. Unlike close, a `404` here is not routine — it means you are polling for something that does not exist

### decision stays null forever
- no `match` — `"decision":null` on every poll
- cause: nobody has given a **SHARED** response. Either no one has answered at all, or every answer so far was `PERSONAL` — those are acknowledgements and never become a decision
- fix: if you need an answer, the options must include at least one `SHARED`; two `SHARED` options is how you ask a question with two answers. And set your own timeout — M91 keeps an alert open until somebody closes it, so an agent waiting on `decision` waits forever by default

### A response came back but decision is still null
- no `match` — `responses` has entries, `decision` is `null`
- cause: **by design.** Only a `SHARED` response decides. A `PERSONAL` response records that one person is aware and changes nothing for anybody else; surfacing it as a decision would let an agent read "Seen" as "Approved"
- fix: read `decision` for the answer and `responses` for the full picture. If those options were meant as answers, give them `effect: "SHARED"`

### Polling gets 429 RATE_LIMITED
- match: `"code":"RATE_LIMITED"` on `GET <SEND_LINK>/alerts/...`
- cause: polls share the send link's 60-per-minute limit with the alerts it raises, so a tight loop burns the budget and then cannot raise alerts either
- fix: poll every few seconds, not continuously. A person is deciding; sub-second polling buys nothing

## Behaviour that looks like a bug and is not

### A SHARED response did not close the alert
- no `match` — the alert stays `OPEN` after somebody responds
- cause: **by design.** `isAutoClose` defaults to `false`. A `SHARED` response stands every other phone down immediately, but it does not end the alert: closing says the thing is *over*, and usually only a person can say that. Auto-closing removes the alert from everyone's screen before anybody can see who took it or what came of it
- fix: nothing, if you want a record somebody can act on and close. Send `isAutoClose: true` for genuine fire-and-forget. See [When an alert ends](https://m91.msg91.com/api/public/docs.md#when-an-alert-ends)

### An alert with no response options never closes
- no `match` — the alert sits `OPEN` indefinitely
- cause: nothing can settle it. With no options there is no response to give, and with `isAutoClose` defaulting to `false` nothing closes it automatically
- fix: for a pure notice, send an explicit empty `responseOptions: []` **together with** `isAutoClose: true` — that pair means "nothing to answer, nothing to follow up", and it closes on delivery. Otherwise close it from your own code, or offer a response somebody can give

### Somebody wants to change their answer
- no `match` — there is no endpoint for it
- cause: **by design.** One response per person, and it is final. A `SHARED` response can never be superseded — somebody has taken responsibility, and the alert has an owner from that moment
- fix: nothing to fix. If the situation changed, that is a new alert, or a comment from the person in the app

### No phone call on an unanswered alert
- no `match`
- cause: the alert was `LOW` or `MEDIUM`, which interrupt every phone but never dial. Only `HIGH` and `CRITICAL` escalate to calls, 45 seconds after nobody has responded. A call is also skipped if somebody already responded, if that person was called for anything in the last 5 minutes, or if the channel's hourly call quota is spent
- fix: use `HIGH` or `CRITICAL` when a call is genuinely warranted. Note that omitting `severity` gives `MEDIUM`, which does not dial — that default is deliberate

### The alert went to the wrong people
- no `match` — it delivers successfully to a channel you did not mean
- cause: the link belongs to a different channel than you thought. Most likely once an account has several
- fix: bare-`GET` the link and read `data.channel.name` before wiring it in. Keep one link per channel per integration, and name the sender when you create it so the app shows which integration filed each alert
