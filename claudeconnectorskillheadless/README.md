# More easily authenticate and connect Claude Code to a wider range of services, even on headless machines

**What:** a toolkit that lets Claude Code more easily authenticate and connect to a user's
third-party accounts — including key services not supported out of the box by claude.ai
connectors, such as Meta Ads, Facebook, Instagram, Google Ads, Google Analytics, and
Microsoft 365 with full read/write. It works even on **headless** machines where the
normal interactive-browser OAuth flow can't run.

This repo focuses on what we think is the hard part — **authenticating and generating the
credentials** for Claude Code to use. It is **not** an MCP server, nor a set of skills for
*using* the credentials: once Claude has them, it generally already knows what to do.

**Who it's for:** anyone running Claude Code or a Claude agent — especially headless
(server, container, chat bot) — that needs to authenticate to outside services.

## Why this exists

Connecting third-party services to Claude has real gaps. This repo fills them:

- **Not every service has a claude.ai connector.** Important ones — Google Ads, Google Analytics, Meta
  (Facebook / Instagram / Ads), and others — have no official connector at all. We provide custom runbooks that guide the user through the authentication process.
- **Some connectors are capability-limited.** Where one exists it can be restrictive: e.g.
  the Microsoft 365 connector is **read-only** and works **only with a work/school account**
  (no personal accounts, no sending or editing).
- **Picking the right method is non-obvious.** Each service has a best way to connect that
  trades off ease vs. capabilities — it could be the official connector, a custom OAuth
  runbook, or DCR. We provide an **opinionated lookup** (`connectorskill.md`) that names
  exactly one recommended path per service.
- **Complex services need hand-holding.** Some take many fiddly portal steps. We ship
  **custom, battle-tested runbooks** that walk the user through them one message at a time —
  Google Workspace (`googleworkspaceoauth.md`), Google Ads (`googleadsconnect.md`), Google
  Analytics (`googleanalyticsconnect.md`), Microsoft 365 (`microsoft365connect.md`), Meta —
  Facebook / Instagram / Ads (`metaconnect.md`), and more.
- **Claude Code's MCP auth assumes a local browser.** Its built-in OAuth opens a system
  browser and listens on `localhost`, which **breaks on a headless terminal** (server,
  container, chat-driven session). These scripts complete the same flow without one — via a
  public tunnel that catches the callback (DCR) or a copy-back `localhost` URL — and deliver
  secrets to the kernel keyring, never to stdout or disk.

## How to use (Claude Code)

This repo is read by *Claude*, not run by you. Make it available to your agent and point
your `CLAUDE.md` at the lookup so Claude consults it whenever a connection is needed:

1. Put this repo where your agent can read it (clone or vendor it into your project, e.g.
   `./claudeconnectorskillheadless/`).
2. Add a pointer to your `CLAUDE.md` — for example:

   ```md
   ## Connecting services
   To connect or authenticate any third-party service (Google, GitHub, Microsoft 365,
   Slack, …), read `claudeconnectorskillheadless/connectorskill.md` and follow it — it
   picks the best method and drives the flow, storing secrets per `storingsecrets.md`.
   ```

That's it. From then on, when you ask Claude to "connect X", it opens `connectorskill.md`,
picks the right method (claude.ai connector / custom runbook / DCR / OAuth-localhost), and
walks you through it.

## What's in here

- **`connectorskill.md`** — the per-service method lookup (start here).
- **Per-service runbooks** Claude follows: `googleworkspaceoauth.md`, `googleadsconnect.md`,
  `googleanalyticsconnect.md`, `microsoft365connect.md`, `metaconnect.md`, `serpapiconnect.md`,
  `githubconnect.md`, `xeroconnect.md`, `resendconnect.md`, `simplybookconnect.md`.
- **`storingsecrets.md`** — how the resulting secrets are named and stored.
- **`connectdcr.mjs`, `connectlocalhost.mjs`, `refresh.mjs`** — the zero-dependency CLIs
  (DCR over a random tunnel, OAuth with a `localhost` callback, token refresh).

## How it works

The design rules, per-script internals (flags, the DCR daemon + kernel-keyring model,
lifecycle, exit codes), and the security model are in **[`ARCHITECTURE.md`](ARCHITECTURE.md)**.
DCR additionally needs the `cloudflared` binary and a usable kernel keyring (`keyctl`).
