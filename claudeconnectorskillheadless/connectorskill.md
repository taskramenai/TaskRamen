---
name: connect-service
description: >-
  How a Claude harness should authenticate and connect a user's third-party
  service (Slack, HubSpot, GitHub, Google, Stripe, …) so Claude can act on it.
  Picks the first method that applies, in order: official claude.ai connector
  (if read+write AND broad) → DCR with random tunnel → simple API key/PAT →
  OAuth with localhost → OAuth with permanent-URL-only.
---

# Connecting a service to Claude

> **Run this interactively — never as a background / fire-and-forget job.** These
> flows are multi-step and require the user to reply between steps (accept a
> waiver, paste an OAuth `client_id`/`client_secret`, open an auth URL and paste
> the callback). Drive them in a session that can receive the user's replies; a
> detached background agent that only reports on completion cannot, and will hang
> or fail partway.

## Before connecting — is it already connected?

**Check first; never re-run a flow that's already done.** Before any method below:
1. **`.env`** — look for the service's secret(s) (e.g. `grep -i <service> "$CLAUDE_HOME/.env"`). Present *and* a quick read works ⇒ already connected; tell the user and stop.
2. **claude.ai connectors** — for connector-based services, check `/mcp` (or the live tool list) for the service's MCP tools.
3. **Complex services (e.g. Google Workspace) — confirm *what* is connected**, not just that something is: a bundle can be partial. List the stored scopes / sub-services actually present, so you reconnect only the missing piece.

## Approach — order of preference

Resolve the connection method in this precedence (and **verify live** at each step):

**1. Custom runbook — FIRST, ALWAYS.** Look up the service in the
[per-service table](#recommended-approach-per-service--exactly-one-path-each) below.
If its row names a **custom runbook `.md` file** (e.g. `googleworkspaceoauth.md`,
`serpapiconnect.md`), **STOP and follow that runbook strictly** — it is a
battle-tested, step-by-step flow
that **overrides everything below**. Do not improvise around it or fall back to the
generic methods.

**2. Per-service table.** Otherwise, use the method named for the service in that
same [per-service table](#recommended-approach-per-service--exactly-one-path-each) —
it lists exactly one recommended path per listed service.

**3. General preference order — services NOT in the table.** If the service is **not
listed**, pick the **first** method below that applies:

1. **Official claude.ai connector** — *only if it passes the connector gate*
   (read+write **AND** broad enough to manage the account). Zero infra; Anthropic
   hosts OAuth + refresh; auto-syncs into Claude Code. **Most preferred.**
2. **DCR with random tunnel** — the service publishes Dynamic Client Registration
   (`registration_endpoint`), so a throwaway trycloudflare tunnel works and **no
   OAuth app has to be created first**. Run `connectdcr.mjs` (see #2).
3. **Simple API key / PAT** — the service issues a long-lived key/token you just
   generate (e.g. GitHub PAT). No OAuth app, no browser callback.
4. **OAuth with localhost** — no DCR, but a pre-registered `http://localhost`
   callback is allowed; **an OAuth app must be created first**. Walk the user
   through it (below).
5. **OAuth with permanent URL only** — no DCR, no localhost, no API key; needs a
   fixed **https** callback on an owned domain. **Prefer the official claude.ai
   connector even if its capabilities are incomplete** (tell the user what's
   missing); if none exists, live-research the best option.

> **ALWAYS VERIFY LIVE.** Connector availability, read/write scope, MCP URLs,
> deep-link formats and which method a service supports change frequently. Before
> instructing the user, confirm against `claude.com/connectors/<service>`, the
> provider's developer docs, and (for DCR) a live
> `/.well-known/oauth-authorization-server` probe. The table below is a starting
> point, not ground truth.

> **RELAYING LINKS OVER CHAT (Telegram).** Send every URL as a **tap-to-copy code span**,
> never a clickable link — a tap opens the in-app browser full-screen (hiding your steps,
> maybe wrong session); the user should copy it into their own browser. The Claude Telegram
> `reply` tool has **no HTML mode** and defaults to plain text, which auto-links a bare URL.
> The only formatting is `format: "markdownv2"`, so send the URL in **its own message**
> wrapped in single backticks (keep prose in separate replies — a URL needs no escaping, a
> long body would):
>
> ```
> reply(text: "`<url>`", format: "markdownv2")
> ```
>
> Do this for **every** URL message. **Self-check:** it must render monospace / tap-to-copy;
> if it's a clickable link you sent plain text — resend with `format: "markdownv2"`.

## #1 — Official claude.ai connector

**Connector gate — qualifies only if BOTH:** (a) **read AND write**, and (b)
**broad enough to let Claude manage the account** (create/update core objects, not
a thin slice). A read-only or narrow connector does **not** qualify — fall to the
next method. (Exception: a **permanent-URL-only** service (#5) with no API-key
option uses its connector even if incomplete — see #5.)

Steps to give the user:
1. Open **claude.ai → Settings → Connectors** (`claude.ai/settings/connectors`).
2. Find the service, click **Connect**, sign in, approve the scopes.
3. **Restart Claude Code (or run `/mcp`) before it works** — the connector only
   appears after a restart/refresh; it does not sync mid-session.
4. Requires a **Claude subscription login** in Claude Code — an **API key silently
   disables** claude.ai connectors (`/status` to check, `/login` to switch).

## #2 — DCR with random tunnel → run `connectdcr.mjs` (daemon mode)

`connectdcr.mjs` probes for DCR, stands up a verified random tunnel, registers a
throwaway public client, surfaces the approval link, catches the callback, and
exchanges the code. It always runs in **daemon mode** (`--keyring` is required — there
is no stdout credential mode): the script runs in the background, publishes the auth
URL on a loopback long-poll endpoint, and writes the final credentials into the
**kernel keyring** — so the `refresh_token` never touches stdout, a file, or a log, and
you stay **non-blocking** (Telegram stays responsive while the user approves). The
user's only cue back to you is the word **"done"**.

Needs `cloudflared` **and** a usable kernel keyring (`keyctl` from keyutils) on the
box. Follow these steps exactly.

**Step 0 — preflight.** `command -v cloudflared && command -v keyctl`. Also confirm the
keyring can actually hold a key (the binary alone isn't enough — a container's seccomp
profile can block `add_key`): `i=$(keyctl padd user connect:probe @s <<<x) && keyctl print "$i" >/dev/null && keyctl unlink "$i" @s && echo KEYRING_OK`.
The keyring is **mandatory** — there is no stdout fallback (a long-lived `refresh_token`
must never be at risk of landing in a detached stdout or a log). So if `keyctl` is missing
→ **install keyutils and stop** (tell the user plainly: web-based credential sign-in needs
the `keyutils` package, which isn't present). If `KEYRING_OK` doesn't print (seccomp/quota
blocks the write, or WSL1 has no keyring) → **stop and report the clear cause** (relax the
container seccomp profile so it permits `add_key`/`keyctl`, or clear the key quota). Do
**not** improvise an alternative that prints the token. The daemon itself also fails fast
with a clear `NO_KEYRING` before any link is shown, so you never approve a flow whose token
can't be saved.

**Step 1 — launch the daemon in the background (NO `setsid`), remember the PID.** Pick a
service slug (e.g. `cloudflare`) and a fixed loopback port (e.g. `8765`). Launch with a
plain `&` so the daemon stays in **this shell's session** — that is what lets your later
`keyctl` calls *possess* and read the `@s` key (keyutils gates payload reads on
possession, not uid; a different session — what `setsid` creates — could not read it):
```
mkdir -p "$CLAUDE_HOME/.cache"
node connectdcr.mjs <mcp-url> --scope "<scopes>" \
     --keyring dcr:<service> --keyring-ring @s --port 8765 \
     >"$CLAUDE_HOME/.cache/dcr-<service>.log" 2>&1 &
```
The log is **non-secret** (daemon mode prints no token) and records `daemon pid <N>` once
it starts — read the PID from there for the Step 4 liveness check:
`pid=$(grep -oP 'daemon pid \K[0-9]+' "$CLAUDE_HOME/.cache/dcr-<service>.log" | head -1)`.
This does not block — relay the URL in Step 3 and end the turn; the non-blocking flow is
what keeps the main session responsive and prevents the frozen-agent watchdog from ever
reaping the Telegram plugin (that was the old blocking flow's failure).

**Step 2 — fetch the auth URL (foreground, one bounded call).** This blocks only for
the ~seconds the tunnel needs to come up, then returns:
```
curl --retry 10 --retry-connrefused --retry-delay 2 --max-time 150 -s \
     http://127.0.0.1:8765/authurl
```
- `{"event":"auth_url","url":"…"}` → go to Step 3.
- `{"event":"error","message":"NOT_DCR …"}` → not DCR-capable; kill the PID and fall
  to **#3** (API key) or **#4** (OAuth-localhost). (`/authurl` always returns HTTP 200;
  branch on the `event` field, not the status code.)
- curl empty/fails → the daemon died at setup; read `dcr-<service>.log`, fix, re-run.

**Step 3 — relay to the user, then END YOUR TURN.** Send the URL per the
**RELAYING LINKS OVER CHAT** rule above (own message, backticks, `markdownv2` —
tap-to-copy). Use this template (two messages):
> Open this link in your browser, tap **Approve**, and when you see the **Done — you
> can close this tab** page, reply **done** here. (Any device is fine.)

```
`<url>`
```
Then **stop** — do not poll, do not block. The daemon holds the listener open and
catches the callback automatically; the user copies **nothing** back. (Do **not** warn
about a "can't reach this page" error — that's the #4 localhost flow, not this one.)

**Step 4 — on the user's "done", harvest EXACTLY ONCE (non-blocking).** The daemon stored
the key in the **session keyring `@s`**, which this shell shares with the daemon — so it
possesses the key and can read the payload (this is the whole reason for `@s` over `@u`).
Every call is bounded (`timeout`) and has stdin closed (`</dev/null`) so a wedged keyring
can never hang the turn:
```
id=$(timeout 5 keyctl search @s user dcr:<service> </dev/null 2>/dev/null) \
  && timeout 5 keyctl print "$id" </dev/null
```
> **Run this once. Never `sleep`, loop, poll, or re-`curl` the daemon waiting for the key.**
> A miss is a *turn boundary*, not something to wait on: classify the result, reply, and
> **end the turn** — the user's next "done" re-triggers you. (Holding a Bash call open to
> "wait for it" is exactly what froze the session before.) The daemon does all real waiting,
> in the background.

- **Prints credentials JSON** → write the fields **straight into `.env`** (`chmod 600`) per
  `storingsecrets.md` (`access_token`, `refresh_token`, `expires_in`, `token_endpoint`,
  `client_id`, `scopes`, `resource`), then clear the key: `timeout 5 keyctl revoke "$id"`.
  **Never echo the credentials JSON to Telegram, a status reply, or any file other than
  `.env`** — treat the harvested payload as the live secret it is. Confirm only:
  > ✅ `<Service>` connected.
- **No key yet** (empty `id`) → check the daemon with the logged pid: `kill -0 "$pid"`
  succeeds → approval hasn't landed, reply *"Almost there — give it a few seconds and reply
  **done** again."* and **end the turn**. `kill -0` fails (daemon gone) → read
  `dcr-<service>.log` and re-run from Step 1 with a fresh link. Either way: **one classify,
  then stop** — do not retry in a loop.

> **Why `@s`, not `@u` (verified on a VM).** keyutils gates reading a key's *payload* on
> **possession**, not on having the same uid. A new key defaults to `possessor: read,
> user: view` — and `view` is **not** `read`. The harvesting shell does **not** possess
> `@u` keys, so with `@u` it gets view-only and `keyctl print` fails *after the daemon
> exits* (the daemon was the only possessor). The shell **does** possess `@s`, because it
> and the daemon share one session keyring — so `@s` reads fine, and the key outlives the
> daemon because it lives in the shared keyring. Corollary: **do not `setsid`** the daemon
> — a separate session would break that shared-`@s` possession. (Telegram safety comes
> from the non-blocking launch, not from detaching.)

**Step 5 — refresh later** (no re-sign-in):
`RT=<refresh_token> node refresh.mjs --token-endpoint <…> --client-id <…> --refresh-token-env RT`
→ emits fresh `credentials`; store again.

The key auto-expires (`--keyring-timeout`, default 900s) and dies on a session restart;
the tunnel + listener tear down on completion, `--timeout-ms` (default 11 min), or
Ctrl-C. Do **not** use Claude Code's native `claude mcp add … /mcp` here: it uses a
system browser + localhost loopback, which fails headless. `connectdcr.mjs` swaps the
loopback for the public tunnel so approval on any device routes back.

> **No stdout credential mode.** `connectdcr.mjs` delivers credentials **only** via the
> kernel keyring; there is no `--keyring`-less mode that prints the token. Invoked without
> `--keyring` it stops with `KEYRING_REQUIRED`, and with no usable keyring it stops with
> `NO_KEYRING`. If the keyring is unavailable on this box, fix the box (install keyutils /
> relax seccomp) — do not look for a way to print the token. Combined with the
> **non-blocking** background launch above (the turn ends in seconds, so the frozen-agent
> watchdog never fires), a DCR timeout or failure can never lose a token to a file **or**
> take down a sibling process such as the Telegram poller.

## #3 — Simple API key / PAT

Assume the user is **non-technical**. Deliver **one step at a time**, **wait for
confirmation** before the next, keep each message short.
1. **Deep link (research live).** Send the user a URL that opens the key/PAT
   creation page **with scopes pre-selected** where supported. Example (GitHub
   classic PAT): `https://github.com/settings/tokens/new?scopes=repo,workflow&description=Claude`
   (fine-grained PATs accept `?contents=write&pull_requests=write&…`). Research the
   provider's equivalent — don't assume one exists.
2. **Scopes.** Broad enough for Claude to **run and manage the account**
   (read+write on core objects); **exclude the most sensitive** — account/owner
   transfer, user/member management, billing/payouts, delete-all, secrets/key
   management — unless explicitly needed. Ask if unsure.
3. **Finish.** Have the user paste the key back; store in `.env` (`chmod 600`),
   **never in the repo**, named per service. (If the key needs an account/region id,
   ask the user for it.)

## #4 — OAuth with localhost → create the app, then run `connectlocalhost.mjs`

No DCR, but `http://localhost` works **once an OAuth app exists**. **Live-research
the exact steps for this provider first.** Walk the user through, **one step at a
time, waiting for confirmation** (non-technical, concise).

> **Consolidate links.** Where the provider supports it, build **ONE deep link with
> all required APIs / scopes / permissions prefilled** rather than sending the user
> several links to click. E.g. Google enables every needed API in a single click via
> `https://console.cloud.google.com/flows/enableapi?apiid=<a.googleapis.com,b.googleapis.com,…>&project=<id>`
> — not one link per API. Always minimize the number of clicks the user must make.

1. **Project (if required — e.g. Google).** Some providers need a *project/tenant*
   first. Send a **deep link to the project-creation page with parameters prefilled**
   (e.g. a dummy project name). If a later step needs a value (e.g. **project-id**),
   **prompt the user to send it back**.
2. **OAuth client / app.** Send a **deep link to the OAuth-app creation page with
   settings prefilled where possible** — dummy app name, **Desktop/Installed** type,
   redirect `http://localhost:8080/callback`, scopes. When it returns a **client-id**
   (and **client-secret** for confidential clients), **prompt the user to send them
   back and store securely in `.env`** (`chmod 600`).
3. **Authorize with `connectlocalhost.mjs` (two modes — you keep the session):**
   ```
   # a) generate the link + a session blob
   node connectlocalhost.mjs start --authorize-endpoint <URL> --token-endpoint <URL> \
        --client-id <ID> --scope "a b" [--port 8080] [--resource <URL>] [--extra access_type=offline]
   ```
   → emits `{"event":"auth_url",…}` (relay to the user; **warn the browser will show
   a "can't reach localhost" error — expected — and they must copy the FULL localhost
   URL back**) and `{"event":"session",…}` (**you keep this**). Unlike DCR (#2), this
   flow has **no listener**, so the error page is real and the copy-back is required.
   ```
   # b) when the user returns the pasted localhost URL
   node connectlocalhost.mjs finish --pasted "<localhost-url>" --session '<session-json>' \
        [--client-secret-env VAR]
   ```
   → emits `{"event":"credentials",…}` → **store it** (`.env`, chmod 600). A
   confidential secret goes in an **env var** named by `--client-secret-env`, never
   argv. Refresh later via `refresh.mjs` (see #2, step 5).

- **Vercel — NOT supported by these scripts.** Vercel needs **DCR with a loopback
  redirect**: it auto-registers (no app to create) but **rejects the public tunnel**
  `connectdcr.mjs` uses, and `connectlocalhost.mjs` cannot perform the DCR step (it
  requires a pre-existing `--client-id`). Neither script fits as-is. For writes, use
  a **Vercel REST API token** (#3 flow), or connect Vercel another way until a
  DCR-over-loopback path is added.

## #5 — OAuth with permanent URL only

No random tunnel, no localhost, **no API key/PAT** — needs a fixed **https** callback
on an owned domain. **Use the official claude.ai connector if one exists, even when
its capabilities are incomplete — and tell the user exactly what is missing** (e.g.
"read-only: Claude can view but not change X"). If there is **no** official connector,
**live-research the best solution** (owned-domain named Cloudflare tunnel, a
provider-hosted connector, or a vetted third-party bridge) and propose it.

## Google — clarify which service first

"Connect Google" is ambiguous — it could mean an account that belongs to Claude, the
user's own account, or just web-search data. **If it is not completely and precisely
clear from context which one the user means, ALWAYS present this to the user as a
numbered menu first — do not pre-pick, do not collapse, do not drop an option:**

> **What would you like to set up?**
>
> 1. **A NEW/DEDICATED Google account that belongs to me, your AI Agent Claude.**
>    I will have full read/write to Gmail, Drive, Calendar, Docs, Sheets, Slides.
> 2. **Your own existing Google account** — this will be read-mostly, via the
>    claude.ai connector.
> 3. **Google Search / Flights / Maps** (data, not an account) — we will set up a
>    service called SerpAPI.

**Never merge options 1 and 2.** "A dedicated Google account for Claude" and "the
user's own Google account" are *different paths* with *different write permissions* and
*different setup flows* — collapsing them into one "your Google account" option is the
most common mistake. Option 1 is the workhorse for an autonomous agent (Claude owns the
account and writes freely); option 2 is deliberately read-mostly so Claude never writes
into the user's real Workspace. Present both, every time.

### What to do once the user picks

- **Option 1 — DEDICATED Claude account** (full read/write: Gmail, Drive, Calendar,
  Docs, Sheets, Slides) → **OAuth with localhost** (Claude's own Google **Desktop**
  client). Full read/write is wanted *because the account is Claude's*. **Follow the
  step-by-step battle-tested runbook `googleworkspaceoauth.md`** — Claude drives the
  whole flow conversationally (new account → enable APIs → consent/publish → Desktop
  client → `connectlocalhost.mjs` auth + exchange → store secrets → test).
- **Option 2 — USER's OWN account** → **official claude.ai connector**. Intentionally
  **read-mostly**, and that limit is **desirable** — we do **not** want Claude writing
  into the user's real Workspace. Follow the connector steps in
  [#1 — Official claude.ai connector](#1--official-claudeai-connector) above (claude.ai
  → Settings → Connectors → Google); there is no localhost/OAuth script to run for this
  path.
- **Option 3 — Google Search / Flights / Maps** → **SerpAPI** (API key — search *data*,
  not an account connection). **Follow the runbook `serpapiconnect.md`** (it is the #3
  flow, battle-tested for SerpAPI): get key → live-validate → store `SERPAPI_KEY`.

### Other Google products (offer only if the user clearly means these)

- **Google Ads** → **OAuth with localhost** (Desktop client + Ads API). **Follow the
  runbook `googleadsconnect.md`** (Manager account → developer token → OAuth → store →
  read-only campaign test).
- **Google Analytics (GA4)** → **OAuth with localhost**. **Follow the runbook
  `googleanalyticsconnect.md`** (no developer token / manager account — just the OAuth
  steps, enabling the Analytics Data + Admin APIs, then a read-only report test).

## Recommended approach per service — exactly one path each

| Service | Recommended connection approach | Rationale (concise) |
|---|---|---|
| **Notion** | claude.ai connector | **claude.ai connector** is R+W and broad — passes the gate |
| **Google Workspace — dedicated Claude account** (Gmail/Drive/Calendar/Docs/Sheets/Slides) | OAuth with localhost (own Google Desktop client) — see `googleworkspaceoauth.md` | **OAuth** gives full R+W on Claude's *own* account (what's wanted here) |
| **Google Workspace — user's own account** (Gmail/Drive/Calendar) | claude.ai connector | **claude.ai connector** is intentionally read-mostly — don't write into the user's Workspace |
| **Google Ads** | OAuth with localhost (Desktop client + Ads API) — see `googleadsconnect.md` | No **claude.ai connector** exists; the **OSS MCP** is read-only — so OAuth |
| **Google Analytics (GA4)** | OAuth with localhost — see `googleanalyticsconnect.md` | No **claude.ai connector** exists; the **OSS MCP** is read-only — so OAuth |
| **Google Search / Flights / Maps** | SerpAPI (API key) — see `serpapiconnect.md` | **SerpAPI** returns search *data*, not an account connection |
| **Microsoft 365** | claude.ai connector if read-only is enough → otherwise OAuth with localhost (public-client Entra app) — see `microsoft365connect.md` | **claude.ai connector** is read-only & work-account-only; an **Entra public client** adds write + personal accounts |
| **Cloudflare** | DCR with random tunnel — `mcp.cloudflare.com/mcp` | **claude.ai connector** is Bindings-only — *it* can't manage Pages/Zero Trust/DNS; the **DCR-connected MCP server** has no such limit, so DCR unlocks Pages/Zero Trust/DNS |
| **GitHub — create a repo** | reuse a stored classic PAT with `repo` scope (`POST /user/repos`), else deep-link `github.com/new` — see `githubconnect.md` §1 | No **claude.ai connector** exists; a **PAT** avoids minting a broad token just to create one repo |
| **GitHub — work on a repo (read/write)** | fine-grained, **single-repo** PAT (Contents/PRs/Issues/Workflows) — see `githubconnect.md` §2 | No **claude.ai connector** exists; a **fine-grained PAT** scopes to one repo — verify breadth, since a PAT can silently grant all-repo R+W |
| **GitLab** | simple API key/PAT → self-host MCP | **claude.ai connector** is beta/narrow — can't manage CI/MR/files; a **PAT + self-hosted MCP** covers them |
| **Vercel** | ⚠️ **not supported by these scripts** — needs DCR-over-loopback (tunnel rejected; `connectlocalhost` can't DCR). Use a REST API token for writes. | **MCP** is read-only today and rejects the tunnel (loopback only); a **REST token** handles writes |
| **Dropbox** | DCR with random tunnel — `mcp.dropbox.com` (beta) | No directory tile; the **beta MCP** is R+W via DCR |
| **HubSpot** | claude.ai connector | **claude.ai connector** is R+W — contacts/companies/deals/tickets |
| **Salesforce** | claude.ai connector | **claude.ai connector** is R+W — SOQL, record CRUD, Apex/Flows |
| **Shopify** | claude.ai connector | **claude.ai connector** is R+W — full Admin via GraphQL |
| **Stripe** | claude.ai connector | **claude.ai connector** is R+W — payments/customers/invoices/refunds |
| **Square** | claude.ai connector | **claude.ai connector** is R+W — 40+ commerce services |
| **PayPal** | claude.ai connector | **claude.ai connector** is R+W — invoices/orders/refunds/subscriptions |
| **Plaid** | simple API key (client-credentials token + Link) | **claude.ai connector** is dev-diagnostics only (**no financial data**); the **API key** reaches the actual data |
| **Xero** | claude.ai connector if read-only is enough → otherwise OAuth with localhost → call the Xero REST API directly — see `xeroconnect.md` | **claude.ai connector** is read-only; **OAuth + REST** gives R+W with the same token. Self-hosting `xero-mcp-server` only forwards to the same API for no auth benefit |
| **QuickBooks** | claude.ai connector | **claude.ai connector** is R+W — invoices/estimates/transactions |
| **Mailchimp** | simple API key | **claude.ai connector** is R+W but too narrow (no granular CRUD/automations); the **API key** is fuller |
| **Resend** (transactional email) | simple API key — see `resendconnect.md` | No claude.ai **directory** connector; a **Resend API key** is R+W (send + domains) and is what deployed sites/apps use — the official remote MCP just wraps the same key |
| **Klaviyo** | claude.ai connector | **claude.ai connector** is R+W (~40 tools) — profiles/lists/segments/campaigns |
| **Slack** | claude.ai connector | **claude.ai connector** is R+W — read history, send messages, search |
| **Intercom** | simple API access token | **claude.ai connector** is read-only; the **API token** is R+W |
| **Zendesk** | simple API token | No official **claude.ai connector** exists; use an **API token** |
| **Atlassian** (Jira/Confluence) | claude.ai connector | **claude.ai connector** is R+W — issues/pages, JQL/CQL |
| **Asana** | claude.ai connector | **claude.ai connector** is R+W — tasks/projects |
| **Linear** | claude.ai connector | **claude.ai connector** is R+W — issues/projects/cycles |
| **Sentry** | claude.ai connector | **claude.ai connector** is R+W — issues/events + autofix |
| **Zoom** | simple API: Server-to-Server OAuth app | **claude.ai connector** is mostly read — can't manage meetings/account; a **Server-to-Server OAuth app** can |
| **Calendly** | claude.ai connector | **claude.ai connector** is R+W — event types, links, availability |
| **SimplyBook.me** (booking system) | simple API key (admin tier — `getUserToken`) — see `simplybookconnect.md` | No claude.ai connector / MCP exists; the **admin API User Key** unlocks R+W (services/staff/hours) — the widget key is read-mostly, so pick the admin tier |
| **WordPress** (WordPress.com / Jetpack) | claude.ai connector | **claude.ai connector** (in the directory, OAuth 2.1) covers WordPress.com/Jetpack sites — verify R+W scope live |
| **DocuSign** | claude.ai connector | **claude.ai connector** is R+W — send envelopes/templates, status |
| **Canva** | claude.ai connector | **claude.ai connector** is R+W — generate/edit designs, export |
| **Box** | claude.ai connector | **claude.ai connector** is R+W — files + Box AI |
| **Facebook** (Pages — content/insights) | simple API key (long-lived / System User access token) — see `metaconnect.md` | **Official OAuth MCP** breaks in Claude Code; a **long-lived token** bypasses the OAuth-redirect problem |
| **Instagram** (content/insights) | simple API key (long-lived / System User access token) — see `metaconnect.md` | Same **Meta System User** flow; IG reached via its linked Page |
| **Meta Ads** (Marketing API) | simple API key (long-lived / System User access token) — see `metaconnect.md` | Same **Meta System User** flow; `ads_read`/`ads_management` |
| **WhatsApp API** (WhatsApp Business Platform / Cloud API — *not* the consumer app) | simple API key (long-lived / System User access token) — see `metaconnect.md` | Same **Meta System User** flow; needs a WABA in a Business portfolio |
| **Threads** (Threads API) | simple API key (long-lived / System User access token) — see `metaconnect.md` | Same **Meta System User** flow; calls use `graph.threads.net` |
| **Zapier** | claude.ai connector | **claude.ai connector** is a R+W meta-connector to 9,000+ apps — catch-all |

## Storing credentials

When a script emits a `credentials` event, **store it yourself** — the scripts write
nothing to disk. One secret per env var in `.env` (`chmod 600`, never committed),
named `<OWNER>_<SERVICE>_<TYPE>_<MODE>_<RESOURCE>` (with `<OWNER>` = `USER` for the
user's account or `SERVICE` for the agent's own) so the **name alone** says how to
pick it; keep OAuth bundles together under one shared prefix. Full conventions
(naming, the `USER_`/`SERVICE_` owner prefix, least-privilege selection rule, OAuth
bundles, examples): **`storingsecrets.md`**.

## After storing — test by reading (READ-ONLY)

**Only for services connected via the generic methods (#1–#5) — a service with a custom runbook is tested by that runbook's own test section; don't also run this (no double-testing).** Once credentials are stored, **tell the user they're stored and you'll now test them by reading from the service**, then run a **strictly read-only** test (never write/create/delete):
- **≤5 sub-services** → test them all.
- **Many sub-services** (e.g. Cloudflare — Workers, KV, R2, D1, Pages, DNS, Zero Trust…) → test a **representative sample of ~5**.

Report a short pass/fail tally. **On any failure, give the user a prescriptive fix — not just the cause.** Name the failing sub-service and HTTP status, then tell them exactly what to do and click, and **send the deep link** that takes them straight there (as a tap-to-copy code span — see the RELAYING LINKS rule). E.g. a `403 SERVICE_DISABLED` → *"Open this, click **Enable**, then reply done"* with `https://console.cloud.google.com/apis/library/<api>?project=<id>`; a missing scope → reconnect with the scope added; a `401` → the token expired, refresh it. Research the provider's exact enable/grant URL live; don't send a generic one.

## Security

Never write tokens/keys/PATs/client-secrets into the repo. Store in `.env`
(`chmod 600`) per **`storingsecrets.md`**. Request least-sufficient scopes (see
#3/#4).
