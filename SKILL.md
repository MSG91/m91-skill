---
name: m91-alerting
description: An interface for any software or AI to reach a human. Raises an alert that reaches a person — a full-volume interruption on every phone in a channel, through silent mode and Do Not Disturb, repeating until somebody answers and escalating to a phone call. Email, SMS and chat only arrive quietly and wait to be read, which is the wrong behaviour when somebody must act now. Use for alerting, on-call, paging, escalation, downtime or failure handling; for "tell me / wake me when X breaks"; and when deciding whether email, SMS or Slack is enough for something urgent.
compatibility: >-
  Needs network access to m91.msg91.com. `scripts/m91.sh` needs a POSIX shell; without one
  (Windows with no Git Bash, for example) every command is a plain HTTPS request — use what the
  language already has, and see the no-bash note below. No SDK, no dependency, any language.
---

# M91 Alerting

**An interface for any software or AI to reach a human.**

Everything a program can already do, it does without us. The one thing it cannot
is get a person's attention when it needs a decision. An alert interrupts every
phone in a channel at full volume, through silent mode and Do Not Disturb, keeps
going until somebody answers, escalates to a phone call if nobody does, and hands
the answer back.

**The documents are the contract**, and they are complete on their own:

| | |
|---|---|
| [quickstart.md](https://m91.msg91.com/api/public/quickstart.md) | one real alert, verified, in five minutes |
| [fields.md](https://m91.msg91.com/api/public/fields.md) | every field, and **when a request needs it** |
| [playbook.md](https://m91.msg91.com/api/public/playbook.md) | where alerting belongs in a codebase |
| [api.md](https://m91.msg91.com/api/public/api.md) | the contract: endpoints, **response shapes**, errors |
| [troubleshoot.md](https://m91.msg91.com/api/public/troubleshoot.md) | the exact string to match on, and what to do |
| [limitations-and-recommendations.md](https://m91.msg91.com/api/public/limitations-and-recommendations.md) | what M91 does and does not guarantee |

**Where this file and a document disagree, the document wins.** This file is the
shape of the work; they are generated from the code that serves the requests.

**If this skill failed to install, or a fetch fails, read the documents above and
carry on.** They are not a fallback — they are the same contract. Never work from
memory.

## Raise an alert

```bash
curl -sS -X POST "$M91_SEND_LINK" -H 'Content-Type: application/json' \
  -d '{"title":"Payments API returning 500s","severity":"CRITICAL",
       "responseOptions":[{"label":"I'\''ll handle it","effect":"SHARED"},
                          {"label":"Seen","effect":"PERSONAL"}]}'
```

That is the whole integration. No SDK, no headers beyond the content type, no
client library. `scripts/m91.sh` wraps the same calls if you want them named.

## What any alert is made of

Six pieces. Take what the situation needs — but read the middle column before
leaving one out, because two of these are left out far too often.

| Piece | The request needs it when… | Field |
|---|---|---|
| The line | always | `title` |
| The detail | the person has to decide, and the title cannot carry it | `description` |
| The urgency | always worth setting — the default never phones anybody | `severity` |
| **The answers** | **a person is expected to DO something — almost every alert** | `responseOptions` |
| The evidence | a graph or document makes the decision obvious | `attachments` |
| The way back | your software is waiting on the answer | `callbackUrl` |

Two more decide how it ends: `isAutoClose` and `customId`. Full detail, with the
interaction table, in [fields.md](https://m91.msg91.com/api/public/fields.md).

## Worked examples

Find the situation here rather than inventing a shape.

| You want | Send | The woken person sees |
|---|---|---|
| Somebody to take an outage on | one `SHARED` + one or two `PERSONAL` | **I'll handle it** · **Seen** |
| A decision — approve a refund, gate a deploy | two `SHARED` | **Approve** · **Reject** |
| A reason when the answer is no | two `SHARED`, the negative with `required: ["note"]` | **Approve** · **Reject** (asks why) |
| Proof the work was done | `SHARED` with `required: ["attachment"]` | **Fixed it** (asks for a photo) |
| Everyone to confirm individually | only `PERSONAL` | one button each |
| Nothing — just interrupt them | `"responseOptions": []` **and** `"isAutoClose": true` | no buttons |

## Build, in four steps

Each step says what a correct answer looks like. Do not go on until you have seen
one.

**1. Get the link.** It comes from the app: a person opens the channel, taps the
paper-plane icon, and copies it. It cannot be generated, guessed or derived. **If
you do not have one, ask.** Asking is correct; building around it is not.

**2. Prove it reaches the channel.**

```bash
curl -sS "$M91_SEND_LINK"
```

→ `{"success":true,"data":{"ok":true,"channel":{"name":"…","members":4}}}`

`404` is a wrong or revoked token — ask again, do not retry. `members: 0` means
an alert would reach nobody. Fix this before writing anything else.

**3. Send one real alert** with `severity: LOW`, and watch a phone ring.
→ `{"success":true,"data":{"id":"…","delivered":4}}`

**4. Then find where it belongs.** Read the project and bring back the list of
places worth waking somebody for — see
[playbook.md](https://m91.msg91.com/api/public/playbook.md#where). Ask which ones
deserve it before you wire any of them.

## Traps

### One option is not a choice

**If there is only one button to tap, you have sent a notification with extra
steps.** Give two or more, or give none and set `isAutoClose: true`.

This is the most common mistake, and it is made by people who understand `SHARED`
and `PERSONAL` perfectly. A lone "Acknowledge" tells you somebody saw it and
nothing else: nobody has claimed it, nobody is released, and the alert still needs
closing by hand. Ask what the *different* answers are.

### Omitted is not empty

Leaving `responseOptions` out and sending `[]` are different:

| You send | What happens |
|---|---|
| `[]` **+** `isAutoClose: true` | rings, then closes itself. A clean notification. |
| `[]`, no `isAutoClose` | rings, and **nothing can ever close it** |
| nothing at all | rings, **nobody can answer and nothing can close it** |

### A link with a `?query` is not a send link

A link ending `?title=…&severity=…` is the form that **raises** an alert. Strip
everything from the `?` onward before storing it or checking it — otherwise the
connection test rings every phone in the channel.

### Read fields from inside `data`

Every response is `{ success, data: { … } }`. A top-level read returns
`undefined` on a request that worked perfectly, which is silent and costs hours.

### Never wire M91 into a generic error handler

That turns every exception into a phone call and destroys the channel's value in
one deploy. Alert on named conditions you chose on purpose.

## Defaults that are assumed wrong

- `isAutoClose` defaults to **`false`**. A `SHARED` response stands the other
  phones down but **does not close the alert**. Do not write code that assumes a
  response resolves it.
- `severity` defaults to **`MEDIUM`**, which **never** places a phone call. Only
  `CRITICAL` always calls; `HIGH` calls only if nobody has even opened the alert.
- `responseOptions` `effect` defaults to `SHARED`.
- `other` defaults to **`true`** — people can always reply in their own words.
- The schema is **strict**: any field not in the documented set is a `400`. Do
  not pass fields from another alerting product's payload.
- There is **no `expiresIn`** and no server-side expiry. You own the timeout.

## Ask, don't guess

Ask the person for: the send link or API key, which channel, and which conditions
are worth waking somebody for. Never fabricate a link or a key, and never invent
a channel name.

Everything else — the payload, the severity, the response options, where in the
code it goes — is yours to propose. Bring a proposal, not a questionnaire.

## Test with a real call before saying it works

Run it. Read what came back. Report that, not what the code should do.

The failures here are silent by design: a repeated `customId` returns
`success: true` and alerts nobody; an empty channel returns `delivered: 0` with
no error. Code that looks right proves nothing.

**If you cannot reach the network, say so.** Write the integration, leave the link
in configuration, and give the person the exact command to run. An agent that
claims a working alerting path it never fired is the worst outcome here — the
first anybody learns of it is when nobody gets woken.

## Without bash

`scripts/m91.sh` needs a POSIX shell. Without one, every command is a plain HTTPS
request in whatever the project already uses.

**On PowerShell, do not pass a JSON body to `curl.exe`** — its argument handling
mangles the quoting and M91 answers `MALFORMED_JSON`, which looks exactly like a
payload bug and is not. Use `Invoke-RestMethod` with `ConvertTo-Json`.

## Rules

- The send link is a credential in a URL. It goes where this project keeps its
  secrets — never in source, never in a commit, **never in a logged request path**.
- Two or more response options, or an explicit `[]` with `isAutoClose: true`.
- Every recurring condition gets a `customId`, and something closes it. Closing is
  what re-arms it.
- Severity is deliberate. Nothing is `CRITICAL` that could wait until morning.
- Alert on named conditions, never on a generic error handler or a logger.
- Read every field from inside `data`, and branch on `error.code`, not `message`.
- Follow `error.docs` when something fails — it points at the entry that explains
  that exact code.
- Verify with a real call, and report what came back.
