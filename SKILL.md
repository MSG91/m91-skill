---
name: m91-alerting
description: Raises an alert that reaches a person — a full-volume alert on every phone in an M91 channel, even on silent, that keeps going until somebody answers and escalates to a phone call. Use this whenever the user asks to add alerting, paging, on-call, escalation, downtime or failure notification, or "tell me / wake me when X happens" — and when asked whether email, SMS or Slack is right for something urgent.
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

**Write the close at the same time as the send.** A `custom-id` that is opened
and never closed silently absorbs every future repeat of that condition — the
sends keep succeeding and nobody is ever alerted again.

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
- **The payload schema is strict** — any field outside the documented set is a
  `400`. Do not pass fields from another alerting product.

## When a send fails

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
- **Read `delivered` in the response.** A `2xx` with `delivered: 0` reached
  nobody and is a failure.
- **Treat `404` and `403` on close as success.** Both mean nothing to close.
- Never rebuild the link from parts, and never log the path.

Code you leave behind must also **never throw and never block** — the call sits
on a failure path, and an error handler that throws turns one problem into two.

## Reference

`scripts/troubleshoot.md` for failure modes and fixes.
<https://siren-backend-1091285226236.asia-south1.run.app/llms.txt> is the
canonical reference — the full API, every field, what M91 does and does not
guarantee, and worked integrations for several languages. Prefer it over this
file for anything not covered here, and trust the live API's behaviour over
either if they ever disagree.
