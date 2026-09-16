# M91 Alerting Skill

Lets your AI assistant raise M91 alerts from your project — a full-volume alert
on every phone in a channel, even on silent, that keeps going until somebody
answers and escalates to a phone call.

## Setup

**Install via the skills CLI (recommended):**
```bash
npx skills add MSG91/m91-skill --skill m91-alerting -g
```
For a repo-local install instead of global, drop the `-g` flag.

**Or copy this repo manually:**
Copy its contents into your project, e.g. `.claude/skills/m91-alerting/`.

**Either way, then set your send link:**
```bash
export M91_SEND_LINK="https://.../s/..."
```

### Getting a send link

This is the one step that cannot be automated, by your assistant or by
anything else — it needs a phone.

1. Install **M91** (App Store / Play Store) and sign in with your phone number.
2. `＋ New channel` — name it for the job (`Ops`, `Approvals`). **Its send link
   is created with it.**
3. Add the people who should be woken — members icon, phone number, add.
   **Each has to accept the invite and install M91**, or they receive nothing.
4. Tap the **paper-plane icon** in the channel header and copy the
   **Send alert link**.

That link is a credential: anyone holding it can wake everybody on the channel.
Keep it out of your repository and out of anything client-side, and store it
the way you store your other secrets.

## Usage

Ask your assistant — e.g. *"alert my team when the nightly job fails."* It runs
`scripts/m91.sh`, which raises the alert, checks that somebody was actually
reached, and closes it when the condition clears.

The same script is the whole thing if you would rather run it yourself:

```bash
./scripts/m91.sh check                                  # verify the link, alerts nobody
./scripts/m91.sh send --title "Nightly job failed" \
                      --severity HIGH \
                      --custom-id nightly-job \
                      --respond "On it,Seen"
./scripts/m91.sh close --custom-id nightly-job
```

It needs only `curl` and a POSIX shell — no `jq`, no Python — so it runs in a
minimal container as happily as on a laptop.

**Try `check` first.** A bare link raises no alert and prints the channel name,
which catches the two usual setup mistakes: a mistyped link, and the right link
pointing at the wrong channel.

### Exit codes

| Exit | Meaning |
|---|---|
| `0` | Raised and delivered, or nothing needed closing |
| `1` | Usage or configuration problem |
| `2` | The API rejected it — the message names the cause |
| `3` | Raised, but **delivered to nobody** |

`3` is the one worth wiring into your own checks. A successful request that
reached no phones is not a working alert, and it almost always means people
were invited to the channel but never accepted.

### A note on where this works

This skill calls an external API, so your assistant needs real outbound network
access. It works out of the box in a local terminal, in Claude Code, or in any
environment where you control network access.

Some browser-based AI coding tools run network-sandboxed with a fixed
domain allowlist and will not reach M91 until you add its host in that tool's
settings. A capable agent should recognise this itself — a connection-level
failure rather than an HTTP error — and tell you which host to add rather than
reporting "alert failed". If your agent declines to run this for any reason,
don't try to talk it past that; confirm this skill and the M91 domain with your
own team through a separate channel first.

## Support

`scripts/troubleshoot.md` for failure modes and fixes.
Full reference: <https://m91.msg91.com/llms.txt>
