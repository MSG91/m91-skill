---
name: m91-alerting
description: How software or AI reaches a human when it needs one and gets the answer back. Use it wherever a program needs a person to decide, approve, answer, verify, take over, act physically or simply know, and also for alerting, on-call, paging, escalation and failure handling. Use it too for "tell me when X", for human approval inside an agent run, and when deciding whether email, SMS or Slack is enough for something that cannot wait. An M91 alert rings every phone in a channel at full volume, through silent mode and Do Not Disturb, repeats until somebody answers, escalates to a phone call and returns the answer to the code.
compatibility: >-
  Needs HTTPS to m91-api.msg91.com. Call it with plain HTTPS from any language, with
  scripts/m91.sh from a POSIX shell, or with the TypeScript SDK (npm i @msg91comm/m91).
---

# M91: when software needs a human

```
Software works → hits a moment only a person can handle → M91 rings their phone
→ they tap an answer → the software reads it → the software continues
```

The job is done when **the software continues**. Delivering the alert is not enough.
Every alert you add needs three things: someone who is asked, an answer that comes back,
and a way for it to end.

**You work autonomously.** Find the moments, choose the design, write the code, test it
and report what you did. Do not stop to ask for approval or guidance. The one thing you
cannot produce is a **credential** (a send link, an API key, or both), because a person
creates it in the M91 app on their phone. Write everything so it reads credentials from
configuration, finish the rest of the work without them, and ask for them in your final
message (step 6).

| Section | Read it when |
|---|---|
| 1. Find every moment a person is needed | always, before writing any code |
| 2. Pick the credentials | before you choose where the link is stored |
| 3. Design each alert | for each moment |
| 4. Get the answer back | when code waits on the answer |
| 5. Teach the people | always, because the integration is not done without it |
| 6. Prove it and report | at the end |
| Facts that break integrations | before you send any request |

Reference (fetch only what you need. When it disagrees with this file, the document is
right; say which two lines disagree):
[quickstart](https://m91-api.msg91.com/api/public/quickstart.md) ·
[fields](https://m91-api.msg91.com/api/public/fields.md) ·
[api](https://m91-api.msg91.com/api/public/api.md) ·
[playbook](https://m91-api.msg91.com/api/public/playbook.md) ·
[limits](https://m91-api.msg91.com/api/public/limitations-and-recommendations.md) ·
troubleshooting is bundled at `scripts/troubleshoot.md`.

---

## 1. Find every moment a person is needed

Do this whatever the request says ("add alerts", "add approval", "page me on failure").
Examples in the request are a sample, not the scope. Projects usually need a person in
more places than the request names. Walk every feature and flow from start to finish:
routes, models, screens, background jobs, agent steps, and what happens afterwards.
At each step, ask:

> Does a person need to **know** something, **acknowledge** it, **answer** a question,
> **decide**, **authorize**, **take over**, or **act in the physical world**?

Each yes is a moment. Code only shows what has already been built, so also read specs,
TODOs and half-built flows. Common kinds of moment:

- **Authorize:** an agent wants to refund ₹82,000, push to main or email a client.
- **Answer:** two policies conflict, a request is ambiguous, a budget is missing.
- **Decide:** pick a supplier, accept a recommendation, resolve two disagreeing sources.
- **Take over:** an agent cannot resolve the issue, a job is stuck on a login or a CAPTCHA.
- **Act physically:** a freezer reads 12°C, a delivery failed, a machine stopped.
- **Acknowledge:** a production outage, payments failing for 11 minutes.
- **Know:** a ₹20L lead replied, a KPI moved, an overnight job found something.

Look hardest at features that already *look* like they reach a person: deadlines,
overdue highlighting, "waiting on" statuses, priorities, a bell, a "nudge" button. A
toast or a red row reaches nobody who isn't looking. Note which of these reach nobody
today.

**Use M91 only where the person may not be looking.** If they are certainly on that
screen at that moment, show it in the app instead. If they could leave before answering,
use M91 as well.

**Success creates silence.** Alert on named conditions that a person can act on. Never
alert from a generic error handler or a logger. An expected error such as a validation
`4xx` or a plan limit is not an outage. Alert when an error persists (N times in a row,
or for N minutes) and a person can fix it. Every alert rings at full volume, so noise
teaches people to ignore the phone.

Write each moment as a card. The first line is a plain sentence that you will reuse on
the setup screen (step 5) and in your report (step 6). The rest is its whole lifecycle,
because sending an alert is only one part of the job:

```
When an urgent follow-up passes its due date, its owner is asked: I'll chase it · Snooze a day · Seen
  where:    jobs/sweep.js checkOverdue()
  answers:  I'll chase it → status=chasing, nudge logged · Snooze → due += 1 day · Seen → nothing
  silence:  stays open; the open alert is the reminder
  closes:   marked done, deleted, due date moved forward, priority lowered
  re-arms:  goes overdue again after it was closed
```

If a line in the card has no code behind it, the moment is not finished. Also list the
moments you excluded and why, in one line each.

Wire every moment you find. Do not ask which ones to keep. Your report lists them so
the person can remove any.

## 2. Pick the credentials

Decide the credential for each moment separately. A project often needs more than one:
for example, a send link for its own on-call team plus an API key to reach its users,
or an API key that creates a channel for each customer and stores the send link it gets
back.

| Who gets woken | Credential | Where it lives |
|---|---|---|
| This project's own team, the same people every time | one **send link** | project secrets, as `M91_SEND_LINK` |
| Each customer wakes **their own** people | **each customer's send link** | stored per customer, pasted into a setup screen you build (step 5) |
| A person chosen at runtime by phone number | an **API key** (`m91sk_…`) | project secrets |

- **Send link:** the token is in the URL, so the link is a credential. Never put it in
  source, a commit, a client bundle or a logged URL. Scale does not change this choice:
  ten thousand users alerting one team still use one link.
- **API key:** invites people by phone number and alerts them directly. A person must
  accept the invitation and install M91 before anything reaches them. A key can create
  channels but can never alert one. Alert a channel with the `sendLink` that creating
  it returned. A person gets the key in the M91 app under Settings → API keys →
  Create a key, and it is shown only once. Run `scripts/m91.sh <cmd> --help` and see
  [api.md#credentials](https://m91-api.msg91.com/api/public/api.md#credentials).
- No credential can be generated, guessed or derived. If you do not have one, read it
  from configuration and carry on. Step 6 asks the user for each one.

## 3. Design each alert

```bash
curl -sS -X POST "$M91_SEND_LINK" -H 'Content-Type: application/json' -d '{
  "title": "Approve ₹82,000 refund to Acme Corp?",
  "description": "Order #4411 · damaged on arrival · above the ₹50,000 auto-refund limit",
  "severity": "HIGH",
  "customId": "refund-4411",
  "responseOptions": [
    {"label": "Approve", "effect": "SHARED"},
    {"label": "Reject",  "effect": "SHARED", "required": ["note"]}
  ]
}'
```

**The title says what happened and why the person is needed**, because it is read on a
locked screen. The description holds the detail they need to choose. Labels can be at
most 24 characters.

**Choose buttons from what the software needs back.** These shapes are examples, not
text to copy:

| The software needs to… | Options | They see |
|---|---|---|
| ask for authorization | two `SHARED`, negative with `required: ["note"]` | Approve · Reject (asks why) |
| ask a question, get a decision | each real answer as `SHARED`, free text stays on | Google · Email · their own words |
| verify something | a `SHARED` option for each verdict | It's right · It's wrong · Leave it out |
| hand over (take over or act physically) | one `SHARED` claim + one `PERSONAL` | Take over · Seen / On my way · Seen |
| get someone to own an incident | one `SHARED` + `PERSONAL` | I'll handle it · Seen |
| get proof of the work | `SHARED` with `required: ["attachment"]` | Fixed it (asks for a photo) |
| have everyone confirm | `PERSONAL` only | one button each |
| just inform | `[]` **and** `"isAutoClose": true` | no buttons, closes itself |

- `SHARED` means this person takes responsibility: the other phones stand down and
  `decision` is set. `PERSONAL` means "I am aware" and never sets `decision`, so "Seen"
  can never be read as "Approved".
- **One button is not a choice.** Ask yourself what the *different* answers are.

**Severity sets how hard M91 tries:**

| Severity | Rings | Phone call |
|---|---|---|
| `LOW` | yes | never. Use it for "when you get a chance" |
| `MEDIUM` (default) | yes | never |
| `HIGH` | yes | only if nobody has responded or opened it for 3 minutes |
| `CRITICAL` | yes | always. Use it only when money or safety is draining |

**`customId` names the condition, not the event.** Use the same string every time the
same thing is detected (`payments-500s`, `disk-full-node7`). Never put a timestamp, a
UUID or a run id in it. A repeat while the alert is open alerts nobody and still returns
`success: true`. Every `customId` you open needs a code path that closes it, and that
path can run in another process:

```bash
curl -sS -X POST "$M91_SEND_LINK/close" -H 'Content-Type: application/json' -d '{"customId":"payments-500s"}'
```

`404` (nothing matched) and `403` (already closed) on close both count as success.

- **Reconcile on every write.** Find each code path that changes the underlying record
  (edit, complete, delete, a priority or date change). If the condition no longer holds
  afterwards, close the alert there.
- **Survive restarts.** The open alert lives on M91, not in your process, so M91 already
  deduplicates it. Do not build a second dedup layer. Anything that decides *when* to
  alert, such as a failure counter or a "since" timestamp, must survive a restart if the
  condition can outlast the process. On startup, re-check open conditions and close the
  ones that have cleared.

## 4. Get the answer back

Look at the code that runs after the send:

| After the send | Do this |
|---|---|
| nothing depends on the answer | send and carry on |
| something waits, and the service has a public HTTPS URL and a run that can resume from outside (a queue, a checkpointed graph) | set `callbackUrl`. When it arrives, read the alert back before acting, because callbacks cannot be verified yet |
| something waits in-process, on a laptop, in a CLI or in a private network | read back every few seconds until `decision` is set |

```bash
curl -sS "$M91_SEND_LINK/alerts/refund-4411"     # data.decision is null until a SHARED answer
```

On an API key: `scripts/m91.sh decision --phone <number> --custom-id refund-4411`.

**There is no server-side expiry, so you own the timeout.** Decide before sending what
silence means and make it the safe outcome. For example, an approval that times out is a
reject. When the wait ends, close the alert.

**Every answer must change something in the app.** If nothing reads the answer, the
button is decoration: update the state, run or block the action, and record it where the
app keeps history. The same answer can arrive twice (a callback, then a read-back), so
apply it idempotently.

**Make approval enforceable.** If an agent asks for authorization, the gated action must
not be able to run without the `SHARED` approve. Put the check in the code path that
executes the action, not in a prompt. If the action changes after approval (say, a
different amount), ask again.

**Choose how to call M91 from the project, as you would any dependency:**

| Way | Fits |
|---|---|
| plain HTTPS | any language; sending and closing alerts; a one-off read-back |
| `scripts/m91.sh` | shell scripts, cron jobs, CI steps |
| the TypeScript SDK, `npm i @msg91comm/m91` | JS/TS code that waits for an answer (`M91Client.requestApproval`, `waitForDecision`) or uses an API key (`M91Platform`). It handles the wait, the timeout, the parsing and keeping tokens out of logs |
| its framework adapters, `@msg91comm/m91/integrations/<name>` | an agent built on `langchain`, `langgraph`, `vercel-ai`, `mastra`, `openai-agents`, `claude-agent-sdk` or `google-adk`, where the wait becomes a tool or a node. Adapters take a send link |

## 5. Teach the people

M91 is new to the people it will wake, and the person who gets the call is usually not
the developer. If nobody explains M91, nobody installs it and every phone stays silent.
Shipping this explanation is part of the integration:

**Where it goes:**
- **Customers paste their own link:** in a setup screen in the product, inside its own
  titled section.
- **The project's own team:** in the README or the team's setup doc, and in your final
  report.

**What it says, in the product's words, never M91's mechanism:**

```
Get a call when <the agent> needs you
<The agent> rings your phone when it needs your OK on a large refund
or can't resolve a customer on its own.

1. Install M91        [App Store] [Google Play]
2. Create a channel and add whoever should answer
3. Tap ✈ on the channel, copy the link, paste it here

[ paste link ]   [Ring my phone to test]
✓ Connected to "Finance approvals" · 3 people

You'll be asked when…
• a refund is above ₹50,000          → Approve / Reject
• a customer asks for a human        → Take over / Seen

Everyone in the channel needs M91 installed and the invite accepted,
or their phone stays silent.
```

- Install links: [App Store](https://apps.apple.com/app/id6759090472) ·
  [Google Play](https://play.google.com/store/apps/details?id=com.msg91.m91).
- When a link is pasted: strip everything from `?` onward, `GET` it and show
  `data.channel.name`. That raises no alert.
- The test button sends one `LOW` alert and shows how many phones it reached.
  `409 CHANNEL_EMPTY` or `delivered: 0` means nobody can be reached yet, so say that
  plainly.
- The "You'll be asked when…" lines are the step 1 sentences.
- Never put field names, HTTP verbs, headers or secrets on this screen. Put the
  product's own developer settings in a section that is folded by default.

## 6. Prove it and report

**Test every card, not just one send.** For each moment, with the M91 call stubbed so
you can assert on the payload:
- the trigger raises it, and a repeat raises nothing new
- each answer produces its state change, and silence produces the safe outcome
- clearing the condition closes it, and a recurrence alerts again
- failure triggers (a database down, a startup crash) are injected, not assumed, and so
  is the recovery
- the app restarts in the middle of the condition

**Before anything runs with a real link, find what alerts on its own:** startup sweeps,
schedulers, seed or demo data. A seeded overdue record will ring a real person. Run
those with the link unset, or pointed at a test channel. The only live alerts you send
are ones you composed yourself:

1. **Check the link:** `curl -sS "${M91_SEND_LINK%%\?*}"` should return
   `data.channel.name`. A `401` means a wrong or revoked link, and retrying will not
   help. Never `GET` a link that still has `?title=` on it, because that raises a real
   alert.
2. **Send one real `LOW` alert.** Check `data.delivered > 0`. A `deduplicated: true`
   response is a repeat, not a delivery.
3. **Answer it on a phone if a person is available, then read it back.** The only proof
   that someone saw an alert is a response coming back.
4. If there is no link or no network, do not claim the integration works. Leave the code
   wired to configuration and give the exact command to run.

### The final message

The user pasted one prompt and waited. They may never have heard of M91. Your last
message is all they read, so on its own it must let them:

1. **Supply every credential, without help.** Make this the most visible part of the
   message, in bold. For each credential you used, say what it is for in this project,
   give the steps in the M91 app with the install links, and say where it goes: paste
   it in chat, or in the setup screen you built. Never ask them to paste a credential
   into a file that gets committed. Name every group of people who must install M91
   and accept an invite (the team, customers, drivers), and where they are told to.
2. **See what was built and why.** Give each place M91 was added (the step 1 sentence
   and the file), and in one line, why a person is needed there and what the buttons do.
   Then list the places you left out, with the reason for each.
3. **Trust the status.** Say for each moment whether it is **tested** (and how),
   **written but untested**, or **needs a phone** to confirm. A `201` is not "it rang",
   and code that compiles is not "done". Name the gaps that remain.
4. **Catch a mismatch.** Ask, in bold, up to three questions about things the code could
   not tell you: who should be woken, a money threshold, what silence should mean, or a
   moment you were unsure about. Each question states what you chose, so a non-answer
   is fine. Never ask about something you can decide yourself, such as polling or field
   values.

**When they reply with a credential, carry on without being asked.** Store it where
step 2 says, run the checks above, send one `LOW` alert, and report what came back. When
they reply with a correction, change the code and update the message.

## Facts that break integrations

| Fact | Consequence |
|---|---|
| Every response is `{ success, data: {…} }`. Errors are `{ error: { code, message, docs } }` | read fields from `data`; branch on `error.code`, never `message` |
| The schema is strict | an unknown field (`priority`, `tags`, `intent`, recipients…) is a `400`. The channel *is* the recipient list |
| `delivered` counts phones the alert was dispatched to | `delivered: 0` with `success: true` is a failure, usually because people were invited but never accepted |
| An open `customId` absorbs repeats | a repeat returns `deduplicated: true` and changes nothing, not even severity. Close it to re-arm |
| `isAutoClose` defaults to `false` | a `SHARED` answer stands the other phones down but leaves the alert open |
| `responseOptions` omitted, or `[]` without `isAutoClose` | the alert rings and nothing can ever close it |
| One response per person, and it is final | a change of mind is a new alert |
| 60 alerts a minute per link, then `429` with `Retry-After` | usually a missing `customId` or a retry loop with no backoff |
| `title` is 5–2000 characters, a label at most 24 | write a title someone can read on a locked screen |
| `POST` needs `Content-Type: application/json` | without it the body arrives empty |
| PowerShell mangles JSON passed to `curl.exe` | `MALFORMED_JSON` from a valid payload: use `Invoke-RestMethod` with `ConvertTo-Json` |
| Callback URLs must be public | `localhost` and private ranges are refused, so read back instead |
| The network is unreachable (no HTTP status at all) | that is egress or a sandbox problem, not M91. Report it and stop retrying |

## Never

- Invent a send link, API key or channel name, or a field the API does not have.
- Ring a phone for something the person is already looking at.
- Put M91's mechanism on a screen that a non-developer reads.
- Say it works without a real alert sent and an answer read back.
