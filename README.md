# TaskRamen — the easy AI agent for Small Businesses (SMBs) that actually gets things done

**What:** TaskRamen is an **easy layer on top of Claude Code** that makes all of its power
accessible to Small Businesses — no technical skills required, and it runs securely walled off on
your own machine.

The easy Windows installer sets it up with no complicated command-line steps, and it then runs
persistently in the background, isolated in its own sandbox.

You talk to it over **Telegram**, and it gets on with real work: writing and editing documents,
researching on the live web, running tasks on a schedule, working with your connected accounts
(Google Ads, Meta Ads and more), and building and shipping websites.

You bring your own Claude subscription. We are not affiliated with or endorsed by Anthropic.

This open-source repository is the orchestration layer around Claude Code that turns a
terminal-based developer tool into an always-on assistant you can message from your phone. It
does **not** include the Windows installer — download that from
[taskramen.ai](https://taskramen.ai).

**Who it's for:** anyone who wants the full power of Claude Code without living in a terminal —
small-business owners and managers first, but equally anyone who wants a persistent agent on
their own hardware rather than someone else's cloud.

## What it can do

- **Talk to it on Telegram.** Ask questions, send files, get files back. Long jobs run as
  background agents that report progress and ping you when they're done.
- **Work on a schedule.** "Every weekday at 9am, check X or do Y and message me" — recurring and
  one-off tasks, in your own timezone, surviving restarts.
- **Use the live web.** A persistent stealth Chrome with browser automation, plus SerpAPI for
  search, maps, finance and flights — so answers are current, not from training data.
- **Produce real documents.** Word, Excel, PowerPoint, PDF and Google Docs — created, edited and
  converted with proper libraries, not screenshots of text.
- **Connect your accounts.** Google Workspace, Google Ads, Google Analytics, Microsoft 365, Meta,
  GitHub, HubSpot, Shopify, Xero and more.
- **Give the agent its own Google account.** It can create Google Docs, email you, and check its
  own inbox on a schedule.
- **Build and run a website.** The `website-builder` skill builds, deploys and maintains an SME
  site on Cloudflare + Astro, including takeovers of existing sites.
- **Keep work organised.** Every task gets a `projects/` folder with its own notes and state, so
  multi-session work picks up where it left off. None of it is ever tracked in git.
- **Run more than one.** Multiple copies can run on one Windows machine — one per Windows user,
  each running in an isolated container and fully separated from the others.

## How to use

You need a machine that stays on (a Windows PC, a Linux box or a VM), an **Anthropic Claude Pro
or Max subscription**, and a Telegram account.

**Recommended — download the Windows installer from [taskramen.ai](https://taskramen.ai).** It
sets the whole thing up on your Windows machine in one click and keeps it running persistently
in the background, so there is nothing to configure and nothing to keep open. The installer is
separate and is not in this repository; this repo is the open-source agent core it installs.

If you'd rather run it yourself, or you're on Linux, both self-hosted paths below run the same
code and the same wizard.

**In a container (Podman/Docker):**

```bash
git clone https://github.com/taskramenai/TaskRamen.git ~/taskramen
cd ~/taskramen
podman build -t taskramen .
podman run -it --name taskramen -v ~/taskramen:/home/ccuser/taskramen:Z taskramen
```

**Directly on a Linux host, under systemd:**

```bash
git clone https://github.com/taskramenai/TaskRamen.git ~/taskramen
cd ~/taskramen
./install.sh
```

However you install it, the same interactive wizard runs once and walks you through it:
installing what's missing, pairing your Telegram bot, activating Claude Code on your own account,
and optionally connecting Google Workspace and web search. After that the services start on their
own and stay up — you close the terminal and talk to it on Telegram.

The full flags, prerequisites and hardening options are in
**[`ARCHITECTURE.md`](ARCHITECTURE.md)**; the abbreviated `podman run` above is the short form,
not the hardened one. After installing, run `bash install/verify.sh` for an automated health
check of the required binaries, the services, Chrome/CDP, Claude authentication and Telegram; for
scheduling, the webhook channel and the tunnel, which it does not cover,
[`install/functionalitycheck.md`](install/functionalitycheck.md) is a manual smoke-test script.

## What's in here

- **`CLAUDE.md`** — the agent's operating instructions: the security rules, the Telegram reply
  contract, scheduling, connectors, browser policy. This file *is* the product's behaviour; read
  it first if you want to know what the agent will and won't do.
- **`install.sh` + `install/`** — the interactive setup wizard.
- **`core/`** — the runtime: the Claude session, the freeze/rate-limit monitor, the stealth
  browser, scheduling, hooks, restart and nightly review.
- **`skills/`, `.agents/skills/`** — capability packs (office documents, website builder, flights,
  browser automation, browser hand-off). See [`skills/README.md`](skills/README.md).
- **`claudeconnectorskillheadless/`** — vendored connector runbooks for authenticating third-party
  services headlessly.
- **`browser-viewer/`** — the token-gated live browser view used for hand-offs.
- **`Containerfile`, `entrypoint.sh`, `build-image.sh`** — the container deployment.
- **`docs/`, `examples/`** — API references and runnable starters.

## What to know before you run it

Agentic AI carries real risk, and more of it than a chatbot does. The agent can take a wrong or
destructive action, act on bad information, or get an account flagged for bot-like activity. Two
things also leave your machine by design: everything you say to the agent goes through
**Telegram**, and everything it processes goes to **Anthropic** under your own account's terms.
The container isolates the agent from the rest of your machine, but no isolation is a guarantee.
Treat the whole install directory as sensitive — `.env`, `personalinfo.md`, your scheduled task
prompts and every `projects/` folder live there in the clear.

The security model, the guards that keep local data out of git, and the browser/CDP exposure
notes are in [`ARCHITECTURE.md`](ARCHITECTURE.md) → "Security notes".

## How it works

The architecture, the two deployment modes with their full flags, the service inventory, the
directory layout and the security model are in **[`ARCHITECTURE.md`](ARCHITECTURE.md)**.

## License

This repository — the TaskRamen agent core — is open source under the
[MIT License](LICENSE), Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai).

TaskRamen is open-core: the agent core here is MIT-licensed, while the Windows installer and the
system tray / management application are a separate, proprietary commercial product and are
**not** open source.

The agent core orchestrates Anthropic's Claude Code, which you bring yourself (your own Anthropic
account); there is no AI model included in this repository. Claude Code is installed from
Anthropic's official distribution under Anthropic's own terms and is not redistributed here. We
are not affiliated with, endorsed by, or sponsored by Anthropic; "Claude" and "Claude Code" are
trademarks of Anthropic, PBC. See [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt) for
third-party components.

"TaskRamen" and "TaskRamen.ai" are trademarks of Jobs Jolt Private Limited; the MIT license
grants no rights in those names or logos.
