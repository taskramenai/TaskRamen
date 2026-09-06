# Connecting Xero (accounting — invoices, contacts, transactions, reports)

A **Claude-driven** runbook for connecting a **Xero** organisation so a Claude harness can
read or act on its accounting data. The user picks the path in **Step 0** — read-only via
the official claude.ai connector, or read+write via an OAuth2 app + direct calls to the
Xero REST API (`https://api.xero.com/api.xro/2.0/...`).

This is the headless, conversational replacement for a setup script: **Claude reads this
file and runs the flow itself**, one message at a time, using `connectlocalhost.mjs` for
the authorization URL + token exchange. It corresponds to **connectorskill.md method #1
(claude.ai connector)** for read-only and **method #4 (OAuth with localhost)** for
read/write.

> **No MCP server needed.** Self-hosting `xero-mcp-server` only forwards calls to the same
> REST API using the same OAuth token — it adds a process to run without making the auth
> any easier. We get identical read/write by calling REST directly with the token this
> runbook produces. (See issue #25.)

> **Scope — this connects the USER's OWN Xero organisation.** Always store under the
> **`USER_`** owner prefix; default to **read-only**, write only when the user explicitly
> asks (`storingsecrets.md` §4).

---

## Ground rules for Claude (read before starting)

- **Run interactively — never as a background / fire-and-forget job.** This flow needs the
  user's replies between steps (waiver, pasted Client ID, pasted callback URL).
- **Drive it yourself, one step at a time.** Assume the user is **non-technical**. Send
  **one step**, **wait for confirmation**, keep each message short. Don't dump all steps.
- **Follow the messages and URLs below as written** — wording, order, and redirect
  construction are deliberate.
- **The liability waiver is a hard gate.** Do **not** proceed past Step 1 until the user
  types **"Agree"**. If they type **"Abort"** at any point, stop, delete sensitive
  messages, and return.
- **Never store secrets in the repo.** Tokens and the callback URL are sensitive — store
  per "Storing the credentials" below (`chmod 600`), never committed.
- **The user works in ONE browser** for the whole flow, signed in to **their own** Xero
  account — every link opens in that same window.

### Relaying URLs over Telegram

Every URL must be **tap-to-copy, not clickable**: send it on its own, wrapped in single
backticks, with `format: "markdownv2"`, prose in separate replies. Tell them the first
time: *"Copy this link and paste it into your browser — don't tap it."* Full rule:
`connectorskill.md` → "RELAYING LINKS OVER CHAT". Each `code block` below already includes
the backticks — that block **is** the literal `text` payload.

---

## What gets connected (OAuth path)

**Scopes requested** (Step 4):

```
openid profile email offline_access accounting.contacts accounting.invoices accounting.banktransactions accounting.payments accounting.settings.read accounting.reports.profitandloss.read accounting.reports.balancesheet.read
```

- `openid profile email` — identity sign-in.
- `offline_access` — **required** for a **refresh token** (Xero access tokens last only
  **30 minutes**; without this you'd re-auth constantly).
- `accounting.contacts` — read/write contacts.
- `accounting.invoices` — read/write sales invoices, bills, credit notes.
- `accounting.banktransactions` — read/write spend/receive money & bank transfers.
- `accounting.payments` — read/write payments applied to invoices/bills.
- `accounting.settings.read` — **read-only** chart of accounts, tax rates, tracking
  categories (needed so invoices can reference the right account/tax codes). Deliberately
  **not** the write form — see the "not administering" note below.
- `accounting.reports.profitandloss.read` / `accounting.reports.balancesheet.read` —
  read P&L and balance sheet (reports are read-only by nature).

> **Use the new GRANULAR scopes (not the broad ones).** Xero deprecated the broad scopes
> (`accounting.transactions`, `accounting.reports.read`); apps created **after 2 March 2026
> can only use the granular scopes** — requesting a broad scope returns `invalid_scope`.
> Each **bare** scope is **read+write**; its **`.read`** form is **read-only** — request
> one, not both.

> **This grants broad read/write but NOT administration.** The transactional scopes above
> (`invoices`, `banktransactions`, `payments`, `contacts`) are full read+write — the agent
> can create and edit those records. The one administrative scope, `accounting.settings`
> **(write)**, is deliberately downgraded to **`.read`**: per Xero's scope docs its write
> form manages **Accounts (chart of accounts), TaxRates, TrackingCategories, BrandingThemes,
> Currencies, InvoiceReminders, Organisation and Users** — i.e. org *configuration and user
> management*, not day-to-day data. Xero has **no separate "admin" scope** — that `settings`
> write, plus the connecting user's Xero **role**, is what confers admin-level reach. **Add
> `accounting.settings` (write) only if the user explicitly needs to create/edit accounts,
> tax rates or tracking categories** (note it also exposes Users management).

> **Extend if needed:** `accounting.manualjournals`, `accounting.attachments`, other
> `accounting.reports.*.read` (aged, trialbalance, executivesummary, banksummary,
> budgetsummary, taxreports, tenninetynine), or `payroll.*` / `files` / `assets` /
> `projects` (each bare = R+W, `.read` = read-only).

For a fully **read-only** token, swap each write scope for its `.read` form
(`accounting.contacts.read`, `accounting.invoices.read`, `accounting.banktransactions.read`,
`accounting.payments.read`); `settings` and the report scopes are already `.read`. Keep
`offline_access` either way. Keep this list verbatim unless the user asks otherwise.

---

## Step 0 — Recommend the connector first, then choose the path

Send:

> I can connect Xero two ways:
>
> 1) **Read-only summaries (easiest)** — the official Claude Xero connector. It's quick to
>    set up, but quite limited: it only gives me a few high-level summaries — cash position,
>    profit & loss, financial position, who owes you (receivables), and top customers. I
>    **can't** open individual invoices or transactions, **can't** change anything, and it
>    works with **one** organisation at a time.
> 2) **Read + write (full detail)** — I can pull individual invoices and transactions and,
>    when you ask, create or edit invoices, contacts and transactions. Setup is more
>    involved and takes about 10 minutes.
>
> If you just want quick financial summaries, pick Option 1. If you need invoice-level
> detail or want me to make changes, pick Option 2.
>
> Which would you like — **"Option 1 read-only"** or **"Option 2 read-write"**?

- **Option 1 (read-only)** → **do not run the rest of this runbook**; walk them through the
  connector:
  > 1. Open `claude.ai` → **Settings → Connectors**.
  > 2. Find **Xero**, click **Connect**, sign in, pick the organisation, approve.
  > 3. **Restart Claude Code (or run `/mcp`)** — the connector only appears after a refresh.
  >
  > Note: this needs signing in to Claude Code with your Claude subscription (an API key
  > disables claude.ai connectors).

  (See `connectorskill.md` #1.) Then stop.
- **Option 2 (read-write)** → continue to Step 1.

---

## Step 1 — Liability waiver (HARD GATE)

Send this **verbatim**:

> We will now connect your **Xero** organisation with **full read and write** access by the
> AI Agent.
>
> **WARNING:** The AI Agent will be able to **read, create, change and void** invoices,
> bills, contacts, payments and other accounting records in this organisation. This is
> **your own live** accounting data.
>
> Because of this access, you face risks including **data loss**, **incorrect financial
> records**, **data leakage**, and **account suspension** by Xero for automated activity.
>
> **LIABILITY WAIVER:** By typing "Agree", you accept these risks. To the maximum extent
> permitted by law, you agree to release, hold harmless, and fully indemnify the developers
> against any claims, losses, or liabilities arising from data loss, incorrect records,
> data leaks, or account lockouts.
>
> Type **"Agree"** to proceed. Type **"Abort"** to stop.

- **"Agree"** (case-insensitive) → continue to Step 2.
- **"Abort"** → stop and return.
- Anything else → re-prompt. **Do not proceed without "Agree".**

---

## Step 2 — Register an OAuth2 app in the Xero developer portal

Send:

> **Step 2: Create a Xero app**
>
> In your normal browser, paste this link and sign in with **your own** Xero account (the
> one with the organisation you want me to use):

```
`https://developer.xero.com/app/manage`
```

> Then:
> 1. Click **"New app"**.
> 2. **App name:** anything (e.g. "Claude Agent").
> 3. **Integration type:** choose **"Mobile or desktop app"** (this needs no client secret).
> 4. **Company or application URL:** any URL you own or `https://example.com`.
> 5. **Redirect URI:** enter exactly `http://localhost:8080/callback`
> 6. Tick the terms box and click **"Create app"**.
>
> Reply **"Done"** when the app is created. Or type **"Abort"** to cancel.

Wait for **"Done"**, then send:

> Open your app's **"Configuration"** page and copy the **"Client id"** — a long code like
> `xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`. Paste it here. (Leave the Client secret alone — this
> app type doesn't need one.) Or type **"Abort"** to cancel.

**Validate** the reply: trim it; a Xero Client ID is a 32-character hex/uppercase string.
If it's clearly not an ID (spaces, a URL, very short), re-ask for the **Client id** from the
app's **Configuration** page. Once it looks right, confirm and hold `<client_id>`:

> Step 2 complete. Client ID received.

> **If the portal asks you to verify your email or shows no "New app" button** → the Xero
> account needs at least one organisation. Have them sign up for a free trial / use the
> **Demo Company** at `https://www.xero.com` first, then retry the link above.

---

## Step 3 — Authorization (use `connectlocalhost.mjs`)

You generate the authorization URL, the user signs in and approves, then you exchange the
pasted localhost callback for tokens. The script keeps no state — **you** hold the
`session` blob. This app type is a **public client (PKCE) — no client secret** anywhere.

### 3a — Generate the auth URL

```bash
node connectlocalhost.mjs start \
  --authorize-endpoint https://login.xero.com/identity/connect/authorize \
  --token-endpoint https://identity.xero.com/connect/token \
  --client-id '<client_id>' \
  --port 8080 \
  --scope "openid profile email offline_access accounting.contacts accounting.invoices accounting.banktransactions accounting.payments accounting.settings.read accounting.reports.profitandloss.read accounting.reports.balancesheet.read"
```

`start` prints two JSON lines:

- `{"event":"auth_url","url":"https://login.xero.com/identity/connect/authorize?...","redirect_uri":"http://localhost:8080/callback"}`
  → **relay `url` to the user** (3b).
- `{"event":"session", ...}` → **you keep this whole object**; pass it verbatim to `finish`
  in 3c. Do not show it to the user.

### 3b — Relay the auth URL and collect the callback

Send (put the actual `url` from the `auth_url` event inside the code block):

> **Step 3: Authorize access**
>
> Final step! Use the same browser. Copy and paste this link:

```
`<auth_url value from the start event — the real https://… URL>`
```

> 1. Sign in if asked.
> 2. **Choose the organisation** you want me to use, then click **Allow access**.
>
> After allowing, your browser will show a **"This site can't be reached"** error at a
> `localhost` address — that's expected! Copy the **FULL URL** from your browser's address
> bar. It looks like:

```
http://localhost:8080/callback?code=...&state=...
```

> Paste it here. Or type **"Abort"** to cancel.

**Validate the reply:** it must contain `localhost`. If not, nudge: *"That doesn't look
right — it should start with `http://localhost`. After clicking Allow access the page shows
a 'can't be reached' error; copy the full URL from the address bar at that point."*

Treat the pasted callback URL as **sensitive** (it carries the auth code) — mark the user's
message for deletion at the end.

### 3c — Exchange the code for tokens

```bash
node connectlocalhost.mjs finish \
  --pasted "<full localhost callback URL the user pasted>" \
  --session '<the session JSON from 3a>'
```

It prints `{"event":"credentials","access_token":"...","refresh_token":"...","expires_in":1800,...}`.
If you get `{"event":"error",...}` instead:

- `STATE_MISMATCH` → the pasted URL is from a different attempt; re-send the auth URL.
- `OAUTH_ERROR` (e.g. `access_denied`) → the user declined; offer to retry.
- `EXCHANGE_FAILED` with an `invalid_grant` / redirect error → the redirect URI in the app
  doesn't match exactly; re-check it is `http://localhost:8080/callback` on the app's
  **Configuration** page (Step 2), then re-run 3a–3c.

> **Refresh token required.** If `refresh_token` is `null`, `offline_access` was missing —
> re-run 3a–3c with it present in `--scope`.

### 3d — Get the tenant (organisation) ID — REQUIRED

Every Xero API call needs an **`Xero-tenant-id`** header. The token response does **not**
contain it — fetch it from the connections endpoint with the access token:

```bash
printf 'header = "Authorization: Bearer %s"\n' "<access_token>" \
  | curl -s -K - https://api.xero.com/connections
```

This returns an array like `[{"tenantId":"<uuid>","tenantName":"Demo Company","tenantType":"ORGANISATION"}]`.
Take the `tenantId` (and `tenantName` for display) of the org the user authorized. If
several are listed, ask the user which `tenantName` to use. Confirm:
*"Step 3 complete — authorized for organisation `<tenantName>`."*

---

## Storing the credentials

Store **per `storingsecrets.md`** — *you* store it; the scripts write nothing. This is the
**user's own** Xero org → **`USER_`** prefix, **no client secret** (public client). Keep
the bundle together under one prefix, `USER_XERO_RW`:

```
# .env  (chmod 600, never committed)
USER_XERO_RW_ACCESS_TOKEN=eyJ...                                           # secret (expires in 30 min)
USER_XERO_RW_REFRESH_TOKEN=...                                             # secret (rotates on every refresh)
USER_XERO_RW_CLIENT_ID=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx                    # non-secret (public client id)
USER_XERO_RW_TOKEN_ENDPOINT=https://identity.xero.com/connect/token       # non-secret
USER_XERO_RW_SCOPES='openid profile email offline_access accounting.contacts accounting.invoices accounting.banktransactions accounting.payments accounting.settings.read accounting.reports.profitandloss.read accounting.reports.balancesheet.read'  # non-secret — quote it (spaces)
USER_XERO_RW_TENANT_ID=<tenantId uuid>                                     # non-secret: the Xero-tenant-id header value
USER_XERO_RW_TENANT_NAME=<org name>                                        # non-secret: which org
```

> **Quote `USER_XERO_RW_SCOPES`** — it's a space-separated list; unquoted it breaks
> shell-`source`ing of `.env` (`storingsecrets.md` §1). The rest are single tokens.

> **No `CLIENT_SECRET`** — the "Mobile or desktop app" type is a public client (PKCE
> replaces the secret), so there is no secret to store.

To act on the org: send the access token as `Authorization: Bearer`, plus
`Xero-tenant-id: <USER_XERO_RW_TENANT_ID>` and `Accept: application/json`, to
`https://api.xero.com/api.xro/2.0/...`. To refresh, read the sibling `USER_XERO_RW_` vars
and call `refresh.mjs` (below).

---

## Connection tests (recommended)

Confirm the credentials work before declaring success. **This is the user's LIVE org — run
READ-ONLY tests only. Never create, edit or void records during testing.** Tell the user
*"Credentials stored ✅ — now testing them by reading from your org (read-only)…"*, then
make these **GET** calls (base `https://api.xero.com/api.xro/2.0`, headers
`Authorization: Bearer <access_token>`, `Xero-tenant-id: <tenant_id>`,
`Accept: application/json`):

| Test | Call (read-only) | Expect |
|---|---|---|
| Read org | `GET /Organisation` | 200 |
| Read contacts | `GET /Contacts?page=1` | 200 |
| Read invoices | `GET /Invoices?page=1` | 200 |
| Read accounts | `GET /Accounts` | 200 |

All are `GET`s and change nothing. (A `2xx` proves the matching write scope was granted,
since read and write are requested together; we don't exercise write paths on a live org.)
Report a tally:

> Test Results — Passed: 4/4
> ✅ Read org ✅ Read contacts ✅ Read invoices ✅ Read accounts
>
> You're all set! (I tested read-only — I didn't create or change anything.)

A `401` means the access token expired (refresh, below); a `403` usually means a scope
wasn't granted (re-run Step 3).

---

## Cleaning up sensitive messages

Before finishing, **delete the sensitive messages** from the chat:

- the user's message with the **localhost callback URL** (Step 3b — carries the auth code),
- the **auth-URL message** you sent (contains the `client_id`).

On Telegram, delete each by `message_id`. Then confirm:

> ✅ Setup complete! Sensitive messages have been deleted from the chat.

---

## Finishing up

> Your Xero organisation **`<tenantName>`** is connected. I can now read and (when you ask)
> create or update invoices, contacts and transactions for it.

---

## Later: refreshing the access token

Access tokens expire in **30 minutes**. Refresh with the stored refresh token (public
client — **no** `--client-secret-env`):

```bash
USER_XERO_RW_REFRESH_TOKEN='...' \
node refresh.mjs \
  --token-endpoint https://identity.xero.com/connect/token \
  --client-id '<client_id>' \
  --scope "openid profile email offline_access accounting.contacts accounting.invoices accounting.banktransactions accounting.payments accounting.settings.read accounting.reports.profitandloss.read accounting.reports.balancesheet.read" \
  --refresh-token-env USER_XERO_RW_REFRESH_TOKEN
```

It emits a fresh `credentials` event — overwrite `USER_XERO_RW_ACCESS_TOKEN` with the new
`access_token`.

> **Xero rotates the refresh token on every refresh and the old one stops working.** If the
> response carries a new `refresh_token`, you **must** overwrite `USER_XERO_RW_REFRESH_TOKEN`
> with it. `refresh.mjs` returns the rotated token when present. A refresh token left unused
> for **60 days** expires → re-run Step 3. The `tenant_id` does **not** change on refresh.

---

## Abort & error handling (any step)

- **"Abort"** at any prompt → stop immediately, delete sensitive messages, tell the user
  it's cancelled.
- **No reply for a while** → fine to wait; re-prompt gently.
- **Wrong client ID / redirect / callback URL** → re-ask with the specific correction
  above; never guess on the user's behalf.
- **`401` mid-use** → token expired; refresh and retry. **`403`** → missing scope; re-run
  Step 3 with the right scopes.
