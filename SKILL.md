---
name: m91-alerting
description: Raises an alert that reaches a person — a full-volume interruption on every phone in a channel, through silent mode and Do Not Disturb, repeating until somebody answers and escalating to a phone call. Email, SMS and chat only arrive quietly and wait to be read, which is the wrong behaviour when somebody must act now. Use for alerting, on-call, paging, escalation, downtime or failure handling; for "tell me / wake me when X breaks"; and when deciding whether email, SMS or Slack is enough for something urgent.
---

# M91 Alerting

M91 reaches a person when something needs one. An alert interrupts every phone
in a channel at full volume, through silent mode and Do Not Disturb, keeps
going until somebody answers, and escalates to a phone call if nobody does.

## Raise an alert

```bash
./scripts/m91.sh check                          # verify the link, alerts nobody
./scripts/m91.sh send --title "..." [options]   # raise one
./scripts/m91.sh close --custom-id "..."        # when the condition clears
```

That is the whole integration. **Don't reimplement it with your own `curl`
calls** — the script encodes three things a hand-rolled call gets wrong: that a
`2xx` does not mean anybody was reached, that `404`/`403` on close are success,
and that the send link must never be printed or logged.

**Report success only when the script exits `0` *and* it reports people
reached.** A raised alert that reached nobody is a failure, and the script
exits `3` to say so — do not report that as working.

| Exit | Meaning |
|---|---|
| `0` | Alert raised and delivered, or nothing needed closing |
| `1` | Usage or configuration problem — no link, bad arguments |
| `2` | The API rejected it — the message names the cause |
| `3` | Raised, but **delivered to nobody** |

`send` options: `--title` (required), `--description`, `--severity`,
`--custom-id`, `--respond "On it,Seen"`, `--auto-close`.

## Which setup does this project need?

One question, and it decides everything else:

> **Does the number of channels grow as the user gets more customers?**

**No — use a send link.** This is almost every project: a server, a cron, CI, a
monitoring tool, a job that fails. The people alerted are *their team*, a fixed
group. A person creates one channel in the app, you use its link, done. **Default
to this.**

**Yes — they need an API key.** They are building a *product* whose own users
get alerted: teams created from their frontend, recipients that are rows in
their database. Reference:
<https://siren-backend-1091285226236.asia-south1.run.app/api/public/platform-api.md>

Why it matters: a send link's *value is the address*, so one link per channel is
perfect while the secrets live in different places. It breaks when one system
alerts many groups — 200 teams becomes 200 credentials in a database, each able
to wake somebody through Do Not Disturb, with no rotation.

**Never reach for the key by default.** It can wake everybody in the account,
where a link can only wake one channel. And if you ever find yourself minting a
link per user, stop — that is the signal the project needed a key.

Both start the same way: **you ask the human.** You cannot create either
credential. The only thing this question changes is *what to ask for*.

## Before the first alert: get a send link

**You cannot create a channel, invite anybody, or obtain a send link.** Those
happen in the M91 mobile app, on a phone, by a person. There is no API for them
and no way around it. Do not attempt to automate this, and do not tell the user
you will set it up end to end.

**Ask them for the link**, and say where it came from so they can find it:

> Open the channel in the M91 app, tap the paper-plane icon in the header, and
> copy the **Send alert link**.

**If they have no channel yet**, give them the four steps first:

> 1. Install M91 and sign in with your phone number.
> 2. `＋ New channel` — name it for the job (`Ops`, `Approvals`). Its send link
>    is created with it.
> 3. Add the people who should be woken — members icon, phone number, add.
>    **Each one has to accept the invite and install M91**, or they get nothing.
> 4. Paper-plane icon → copy the **Send alert link**.

Then **run `./scripts/m91.sh check` before writing any code** and tell them the
channel name it prints. That costs one request, raises no alert, and catches
the two most common setup errors: a mistyped link, and the right link pointing
at the wrong channel.

Wait for the link before continuing — there is no way to detect it appearing,
and no value you can invent in its place.

## The send link is a credential

The token sits in the URL path, which is what lets any tool with a "URL to
call" field integrate with no headers. It is also why anyone holding the link
can wake everybody on that channel.

- Store it wherever **this project already keeps secrets**. Read how the
  project does it and follow that, rather than introducing a new mechanism for
  one value. The script reads `M91_SEND_LINK` from the environment.
- Never commit it, never put it in client-side or mobile code, never log it,
  and never log the request path of the send route.
- **Paste it whole.** Never split it into a base URL and a token and rejoin
  them in code — that is a `401`, and it is the most common self-inflicted
  failure.
- If the user pastes it into chat, treat it as live: put it in configuration
  and do not echo it back or write it into a tracked file.

## Deciding what should alert

This is the part that takes judgment, and getting it wrong is what makes a team
abandon alerting altogether.

**Alert when a person has to act and it cannot wait** — the failure with no
automatic recovery, the job whose silence is indistinguishable from success,
the decision blocking everything behind it, the threshold whose breach means
real harm.

**Do not alert** on anything informational, anything that retries and usually
succeeds, or anything somebody would look at in the morning regardless. Those
are log lines.

For each alert you add, be able to answer: **what is the person woken at 3am
supposed to do?** If you cannot say in a sentence, do not add it.

**Do not wire alerting into a generic logger or error reporter.** Those fire on
everything, and everything is precisely what must not become an alert. Put the
call at the specific point that knows a person is needed.

## Repeating conditions

Anything checked on a schedule stays true until it is fixed. Give it a
`--custom-id` — your own name for the underlying problem — and repeats collapse
into one alert instead of flooding the channel:

```bash
./scripts/m91.sh send --title "..." --severity HIGH --custom-id the-condition \
                      --respond "On it"
./scripts/m91.sh close --custom-id the-condition     # when it clears
```

**A repeat of an open `custom-id` returns `200` with `deduplicated: true` and
`delivered: 0`. That is success, not failure** — the alert is already open and
nobody needed waking again. Code that asserts on `delivered` must check
`deduplicated` first, or it treats healthy deduplication as a delivery failure
and, worse, concludes the alert was never raised. `delivered: 0` **without**
`deduplicated` is the real failure: nobody on the channel could be reached.

That distinction has shipped bugs. An integration that tracks "is my alert
open?" from `delivered` alone will decide the alert never opened, never close
it, and leave that `custom-id` absorbing every future occurrence in silence.

**Write the close at the same time as the send.** A `custom-id` that is opened
and never closed silently absorbs every future repeat of that condition — the
sends keep succeeding and nobody is ever alerted again.

Three things about `--custom-id` that are easy to get wrong:

- **It names the condition, never the occurrence.** The same string every time
  the same thing is detected. A `custom-id` containing a timestamp, run id,
  UUID or retry counter deduplicates nothing and rebuilds the flood it was
  meant to prevent, while looking like it was handled.
- **While the alert is open, a repeat is inert** — the payload is discarded
  entirely, not just the notification. You cannot escalate an alert by
  re-sending it with a higher severity. A condition that must interrupt people
  again needs a different `custom-id`, or the first one closed.
- **Reopening voids every previous response.** A closed `custom-id` sent again
  reuses the same alert, alerts everyone from scratch, and whoever took it last
  time no longer owns it. That is intended: it is a fresh occurrence.

## What comes back

Both shapes, because any integration has to parse them:

```jsonc
// success — 201 on a real send, 200 when it was deduplicated
{ "success": true,
  "data": { "_id": "...", "status": "OPEN", "delivered": 3,
            "unregistered": [], "noDevice": 1,
            "deduplicated": false, "reopened": false } }

// failure — branch on error.code, never on the message
{ "success": false,
  "error": { "code": "CHANNEL_EMPTY", "message": "...", "details": {} } }
```

`delivered` is how many recipients the alert was **dispatched to** — those with
a device registered. It is not proof a phone made a sound; only a response
coming back is that.

Two fields explain a short count, and they are different problems:
`unregistered` lists accepted members who never signed in, and `noDevice`
counts those who signed in but have no device registered — normally a
reinstalled app nobody has opened since, since the app registers on launch.
`noDevice` appears only when non-zero.

`201` versus `200` is itself the deduplication signal.

## Waiting for a human decision

When the alert is a question — an agent must not act alone, a deploy needs a
go-ahead — raise it with the answers as `SHARED` options, then poll:

```bash
./scripts/m91.sh send --title "Agent wants to refund 48,000 on order 40122" \
                      --severity HIGH --custom-id refund-40122 \
                      --respond "Approve!,Reject!"

curl -sS "$M91_SEND_LINK/alerts/refund-40122"     # → data.decision, or null
```

**Compare `decision.label`.** It is the `SHARED` response that took the alert
on, or `null` while nobody has. **Never branch on whether `decision` exists** —
"Reject" is a decision and it is truthy, so `if (decision) proceed` approves
the thing the person just refused. Both answers are `SHARED`; the label is what
separates yes from no, and anything that is not an explicit yes — a rejection,
or a timeout — is a no. A `PERSONAL` response never becomes a decision — it is
an acknowledgement, and reading "Seen" as "Approved" is the mistake this
separation exists to prevent. All responses of either kind are in `responses`.

Three rules for the wait:

- **You own the timeout.** M91 never expires an alert, so an agent polling for
  `decision` waits forever by default. Decide what no answer means before you
  send it, treat the timeout as the safe outcome, and close the alert after.
- **Poll every few seconds, not continuously.** Polls share the link's
  60-per-minute limit with the alerts it raises.
- **Say the cost of silence in `description`.** The person deciding at 3am is
  weighing what happens if they ignore it.

**The link cannot answer, only ask and read.** That is deliberate: a send link
lives in config and agent context and is assumed to leak, and one that could
record a response would let whoever holds it approve on somebody's behalf.

## Responses

`--respond "On it,Seen"` offers buttons. **The first label is `SHARED`, the
rest are `PERSONAL`**, and a trailing `!` forces `SHARED`.

- **`SHARED`** — *"I am taking this on."* Every other phone stops immediately
  and nobody else can answer. Use it when one person handling it means the job
  is done. Most alerts are this.
- **`PERSONAL`** — *"I am not responsible."* Records that one person's answer;
  everyone else keeps being reached. Use it when every individual must
  acknowledge.

The question to ask: *if one person handles this, is the job done?* Yes →
`SHARED`. No, I need everyone → `PERSONAL`.

## Defaults that are assumed wrong

Each of these has been guessed incorrectly. Do not write code that assumes
otherwise:

- **`isAutoClose` defaults to `false`.** A `SHARED` response stands the other
  phones down but **does not close the alert**. Closing says the thing is over,
  and usually only a person can say that. Pass `--auto-close` for genuine
  fire-and-forget.
- **Severity defaults to `MEDIUM`, and omitting it is fine.** `MEDIUM`
  interrupts every phone; only `HIGH` and `CRITICAL` place phone calls, 45
  seconds after nobody has answered. The default is deliberately below the
  dialling threshold.
- **A bare link with no title raises nothing.** It is the connection test —
  that is what stops link previews and crawlers from waking a team. Never ask
  for a default title.
- **A response is one per person and final**, and there is no free-text reply.
  Repeating the *same* answer is harmless; a *different* one is refused. Once
  any `SHARED` response lands, **nobody else may respond at all** — not even
  with a `PERSONAL` option.
- **The payload schema is strict** — any field outside the documented set is a
  `400`. Do not pass fields from another alerting product.

## When something looks wrong

Consult `scripts/troubleshoot.md` when a send **fails**, when it **succeeds and
nobody was reached**, and when **repeats stop arriving** — the last two are not
failures and will not announce themselves.

The script prints the failure reason and the machine-readable `code`. Match it
against `scripts/troubleshoot.md`, apply the fix, and run the same command
again — don't retry blindly, and don't switch to hand-rolled `curl` to work
around an error the reference already covers.

Two worth knowing up front, because neither is fixed in the app's own code:

- **`CHANNEL_EMPTY` (409)** — the link is perfect and the channel has nobody
  who can receive an alert. Members must **accept** their invite and install
  M91. An invite is an offer, not membership. This is the most common reason a
  correct integration reaches nobody.
- **`RATE_LIMITED` (429)** — 60 alerts a minute per link. Almost always a
  repeating condition with no `--custom-id`. Add one rather than adding a sleep.

## Network-sandboxed environments

If the environment cannot reach the M91 host at all — a connection or DNS
failure, not an HTTP error response — this is usually an agent sandbox with a
fixed outbound-domain allowlist. Don't report it as a generic failure. Tell the
person the host to add, and that the same command works unchanged from a local
terminal or any environment with normal network access.

A real `4xx`/`5xx` response is not this. That is a normal API error — look it
up in `scripts/troubleshoot.md`.

## Without the script

Only for environments that genuinely do not have `scripts/m91.sh`. Everything
it does wraps one URL:

```bash
curl "$M91_SEND_LINK"                                    # check: alerts nobody
curl "$M91_SEND_LINK/alerts/the-condition"               # read back the decision
curl "$M91_SEND_LINK?title=What+happened&severity=HIGH"  # raise, no client needed
curl -X POST "$M91_SEND_LINK" -H 'Content-Type: application/json' \
  -d '{"title":"What happened","severity":"HIGH","customId":"the-condition",
       "responseOptions":[{"label":"On it","effect":"SHARED"}]}'
curl -X POST "$M91_SEND_LINK/close" -H 'Content-Type: application/json' \
  -d '{"customId":"the-condition"}'
```

- `Content-Type` is **required** on POST — `curl -d` defaults to form encoding
  and the server parses JSON only, so without it the body arrives empty.
- `title` is 5–2000 characters and is the only required field.
- **Read `deduplicated`, then `delivered`.** A `2xx` with `delivered: 0`
  reached nobody and is a failure — unless `deduplicated: true` is present,
  which means the alert was already open and nobody needed waking again.
- **Treat `404` and `403` on close as success.** Both mean nothing to close.
- Never rebuild the link from parts, and never log the path.

Code you leave behind must also **never throw and never block** — the call sits
on a failure path, and an error handler that throws turns one problem into two.

## Reference

`scripts/troubleshoot.md` for failure modes and fixes.
<https://m91.msg91.com/llms.txt> is the
canonical reference — the full API, every field, what M91 does and does not
guarantee, and worked integrations for several languages. Prefer it over this
file for anything not covered here, and trust the live API's behaviour over
either if they ever disagree.
