# Connecting Microsoft 365 (Outlook, Calendar, OneDrive, Contacts)

A **Claude-driven** runbook for connecting a **Microsoft 365 / Microsoft account**
(Outlook Mail, Calendar, Contacts, OneDrive files) so a Claude harness can act on it.
The user picks the path in **Step 0** below — read-only via the official claude.ai
connector (work accounts only), or read+write via a public-client Microsoft Entra
(Azure AD) OAuth app (works for work **and** personal accounts).

This is the headless, conversational replacement for a setup script: **Claude reads
this file and runs the flow itself**, talking the user through it one message at a
time and using `connectlocalhost.mjs` for the authorization URL + token exchange. It
corresponds to **connectorskill.md method #1 (claude.ai connector)** for the read-only
path and **method #4 (OAuth with localhost)** for the read/write path.

> Use the **Entra OAuth path** when the user needs Claude to **act** on the account
> (send mail, create/edit events, upload/edit files) **or** is on a **personal**
> Microsoft account. Use the **connector** when read-only access to a **work** account
> is enough. If it is not crystal clear which the user wants, **ask first** (see Step 0).

> **Scope — this runbook connects the USER's OWN Microsoft 365 account.** Do **not**
> offer to create or use a *dedicated Microsoft account for the agent*. If the user wants
> a **new, dedicated account that the agent owns and fully controls**, do **not** set that
> up here — **direct them to the Google Workspace dedicated-account flow (`googleworkspaceoauth.md`)**,
> which is the battle-tested path for an agent-owned account (Gmail/Drive/Calendar/Docs
> with full read/write). Tell them: *"For a dedicated account that I own and run myself, I
> set up a Google Workspace account instead of Microsoft 365 — it's the supported path for
> that. Want me to do that?"* Microsoft 365 here is **only** for connecting the user's
> existing Microsoft account.

---

## Ground rules for Claude (read before starting)

- **Run interactively — never as a background / fire-and-forget job.** This flow needs
  the user's replies between steps (waiver, pasted Application (client) ID, pasted
  callback URL). Drive it in a session that can receive those replies; a
  detached/background agent that only reports on completion will hang or fail.
- **Drive it yourself, one step at a time.** Assume the user is **non-technical**.
  Send **one step**, **wait for confirmation** before the next, keep each message
  short. Do not dump all the steps at once.
- **Follow the messages and URLs below as written.** The wording, the step order, and
  the URL/redirect construction are deliberate — reproduce them faithfully. Do not
  invent extra steps or reorder them.
- **The liability waiver is a hard gate.** Do **not** proceed past Step 1 until the
  user types **"Agree"**. If they type **"Abort"** at any point, stop, delete any
  sensitive messages, and return.
- **Never store secrets in the repo.** Tokens and the auth callback URL are sensitive.
  Store them per "Storing the credentials" below (`chmod 600`), never committed. (Note:
  a public client has **no client secret** — that is the point; see Step 4.)
- **The user works in ONE browser** for the whole flow, signed in to **their own**
  Microsoft account — every portal link opens in that same window.

### Relaying URLs over Telegram

Every URL must be **tap-to-copy, not clickable**: the user copies it and pastes it into
their own browser. A tap opens Telegram's in-app browser, which hides your instructions,
may be signed into the wrong account, and breaks the localhost callback. Tell them the
first time: *"Copy this link and paste it into your browser — don't tap it."*

**How:** send the URL on its own, wrapped in single backticks, with `format: "markdownv2"`
— that makes it tap-to-copy and a URL inside backticks needs no escaping. Keep your prose
in separate replies. Full rule + self-check: `connectorskill.md` → "RELAYING LINKS OVER
CHAT". Everywhere below, the URL shown in a `code block` already includes the backticks —
that block **is** the literal `text` payload; send it with `format: "markdownv2"`, never
as a plain auto-linked URL.

---

## What gets connected (Entra OAuth path)

**Microsoft Graph delegated scopes requested** (Step 4):

```
openid profile email offline_access User.Read Mail.ReadWrite Mail.Send Calendars.ReadWrite Contacts.ReadWrite Files.ReadWrite.All
```

What each does:

- `openid profile email` — OpenID Connect sign-in (these are **bare** — no Graph prefix).
- `offline_access` — **required** so Microsoft returns a **refresh token** (without it you
  only get a ~1-hour access token).
- `User.Read` — read the signed-in user's profile (used to fetch the account email in 6).
- `Mail.ReadWrite` + `Mail.Send` — read/write mailbox **and** send mail.
- `Calendars.ReadWrite` — read/create/update calendar events.
- `Contacts.ReadWrite` — read/write contacts.
- `Files.ReadWrite.All` — read/write OneDrive **and** files the user can access (incl.
  shared / SharePoint). (`Files.ReadWrite` alone is own-OneDrive only — `.All` is broader.)

Graph scopes work in **short form** (`Mail.Send` ≡ `https://graph.microsoft.com/Mail.Send`);
keep them short and **do not mix** Graph scopes with another resource's scopes in one
request. All of these are **user-consentable** (no admin consent required by the
permission itself) — though a locked-down work tenant's consent *policy* can still route
high-impact scopes (e.g. `Mail.Send`) to an admin (see Step 4 troubleshooting).

Keep this list verbatim — it is what makes the connected account fully usable for an
autonomous agent.

---

## Step 0 — Recommend the connector first, then choose the path

Before anything else, let the user choose. Send:

> I can connect with Microsoft 365 two ways:
>
> 1) **Read-only for Work account (easiest)** — use the official Claude Microsoft 365
>    connector. I can read your Outlook mail, calendar, OneDrive, SharePoint and Teams.
>    Two limits: I cannot send mail, change your calendar, or edit files, and it only
>    works with a work/business Microsoft account — NOT a personal account (@outlook.com /
>    @hotmail.com / @live.com).
> 2) **Read + write, works with Personal and Work accounts** — I can send mail, create
>    calendar events, and edit OneDrive files. Setup is more complex and takes about
>    10–15 minutes.
>
> Which would you like — **"Option 1 read-only for work accounts"** or **"Option 2
> read-write"**?

- **Option 1 (read-only)** → **first confirm they're on a work/business account** (the
  connector won't work with a personal account). If they're on a personal account, tell
  them it won't work and offer Option 2 instead. If it **is** a work account → **do not run
  the rest of this runbook**; walk them through the connector:
  > 1. Open `claude.ai` → **Settings → Connectors**.
  > 2. Find **Microsoft 365**, click **Connect**, sign in with your work account, approve.
  > 3. **Restart Claude Code (or run `/mcp`)** — the connector only appears after a refresh.
  >
  > Note: this requires signing in to Claude Code with your Claude subscription (an API
  > key disables claude.ai connectors).

  (See `connectorskill.md` #1 for the full connector steps.) Then stop.
- **Option 2 (read-write)**, or a personal account that can't use the connector → continue
  to Step 1.

---

## Step 1 — Liability waiver (HARD GATE)

Send this **verbatim**:

> We will now connect your **Microsoft 365** account (Outlook Mail, Calendar, Contacts,
> OneDrive) with **full read and write** access by the AI Agent.
>
> **WARNING:** The AI Agent will be able to **read, send, change and delete** mail,
> calendar events, contacts and files in this account. This is **your own** Microsoft
> account, so the agent acts on your **live** data.
>
> Because of this access, you face risks including **data loss**, **data leakage**, and
> **account suspension** by Microsoft for automated activity.
>
> **LIABILITY WAIVER:** By typing "Agree", you accept these risks. To the maximum extent
> permitted by law, you agree to release, hold harmless, and fully indemnify the
> developers against any claims, losses, or liabilities arising from data loss, data
> leaks, or account lockouts.
>
> Type **"Agree"** to proceed. Type **"Abort"** to stop.

- If the user types **"Agree"** (case-insensitive) → continue to Step 2.
- If they type **"Abort"** → stop and return.
- Any other reply → re-prompt / keep waiting. **Do not proceed without "Agree".**

---

## Step 2 — Sign in to the Microsoft account

Send:

> **Step 2: Sign in to your Microsoft account**
>
> In your normal browser, paste this link and sign in with **your own** Microsoft 365
> account (the one you want me to use):

Then the copy-paste block:

```
`https://portal.azure.com/`
```

> Stay signed in, in this same browser window. One quick question so I send you the right
> steps: is this a **work/school** account (given to you by a company or organisation) or
> a **personal** account (e.g. @outlook.com / @hotmail.com / @live.com, or one you set up
> yourself)? Reply **"work"** or **"personal"**. Or type **"Abort"** to cancel.

- **"work"** → the account already belongs to a Microsoft directory; **skip to Step 3**.
- **"personal"** → a personal account has **no directory** to hold the app, and the
  registration page will fail with *"The ability to create applications outside of a
  directory has been deprecated."* Do **Step 2b first**.
- Unsure → it's almost always personal if the address is @outlook/@hotmail/@live or a
  Gmail/other address they signed up with themselves; work if it's a company domain. If
  still unsure, have them try Step 3 — if they hit the "outside of a directory" error,
  fall back to Step 2b.

---

## Step 2b — (Personal accounts only) Create a free Azure account

A personal account can't host the app registration until it has an Azure account behind it.
Send this message

> Because this is a personal account, Microsoft needs you to first create a free Azure
> account.
>
> It's free, but Microsoft requires a phone number and a credit/debit card to verify your
> identity.

Then send the sign-up link:

```
`https://azure.microsoft.com/free/`
```

> 1. Click **"Start free" / "Try Azure for free"** and sign in with the **same** personal
>    Microsoft account.
> 2. Complete the sign-up (phone + card to verify your identity).
>
> Reply **"Done"** when the sign-up is finished. Or type **"Abort"** to cancel.

Wait for **"Done"**, then continue to Step 3 (the account can now hold the app).

---

## Step 3 — Register the Entra app (public client)

Send:

> **Step 3: Register the app**
>
> Use the same browser (you should still be signed in). Copy and paste this
> link to open **"Register an application"**:

Then the copy-paste block:

```
`https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/CreateApplicationBlade`
```

> 1. **Name:** anything (e.g. "Claude Agent").
> 2. **Supported account types:** choose **"Any Entra ID tenant + Personal Microsoft
>    accounts"** (the option that ends with "…and personal Microsoft accounts").
> 3. **Redirect URI:** in the **"Select a platform"** dropdown choose **"Public
>    client/native (mobile & desktop)"**, then in the box beside it enter exactly:
>    `http://localhost:8080/callback`
> 4. Click **"Register"**.
>
> Reply **"Done"** when it's registered. Or type **"Abort"** to cancel.

> **If the page shows "The ability to create applications outside of a directory has been
> deprecated"** → the account isn't inside a directory yet (the personal-account case). Go
> back and do **Step 2b** to create a free directory, then return here. (If they *just*
> created a directory but still see this, they may be viewing the wrong one — have them
> switch directory via `https://portal.azure.com/#settings/directory`, pick the new
> **Default Directory**, then reopen the link above.)

Wait for **"Done"**. Azure does **not** reliably open the new app afterwards, so now send the
App registrations list so they can open it and read the client ID:

```
`https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade`
```

> Click the **"All applications"** tab, click your app (**"Claude Agent"**), and on its
> **Overview** page copy **"Application (client) ID"** — a long code like
> `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` (use the copy icon beside it).
>
> (If the link doesn't open it, type **"App registrations"** into the top **search bar**,
> open it, then use the **"All applications"** tab.)
>
> Paste the **Application (client) ID** here — **not** the "Tenant ID" (that's a different
> code). Or type **"Abort"** to cancel.

**Validate** the reply: trim it and require it to match a GUID,
`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`. If it
doesn't match, send:

> That doesn't look like an Application (client) ID. It should be a long code like
> `11111111-2222-3333-4444-555555555555`, found on **your app's** Overview page next to
> **"Application (client) ID"** (App registrations → your app). Make sure it's that one —
> **not** the "Tenant ID" (a different code). Please paste it again.

Once valid, confirm and hold onto `<client_id>` (the auth URL and token exchange embed it):

> Step 3 complete. Application (client) ID received.

> **Tenant note.** The above registers a **multitenant + personal** app, so the OAuth
> endpoints below use the **`common`** tenant. If the user deliberately chose
> **"...this organizational directory only"** (single tenant) or **"...any organizational
> directory"** (work only), substitute the tenant segment in **every** `login.microsoftonline.com`
> URL below: single-tenant → the **Directory (tenant) ID** (also on the Overview
> page); work-only → `organizations`; personal-only → `consumers`. When unsure, `common`
> is the safe default.

---

> **No "API permissions" to configure.** If the user asks about the **API permissions**
> page (it shows a default **Microsoft Graph → User.Read**, and the Integration assistant
> flags "Configure API permissions — Action required"), reassure them: **nothing needs to be
> added there.** This flow uses **dynamic consent** — the sign-in URL in Step 4 carries all
> the scopes, and the user grants them on the consent screen. Leave the default `User.Read`,
> ignore the warning, and **do not** click "Grant admin consent" (not needed for a personal
> account; for a managed work tenant, admin consent is only needed if the tenant restricts
> user consent — see Step 4c `AADSTS65001`).

> **Redirect is set in Step 3 — no separate step for it.** The Mobile/desktop redirect
> `http://localhost:8080/callback` is entered during registration (Step 3); its **scheme and
> path must match exactly** (`http` + `/callback`) while the **port is ignored for
> `localhost`**, so `8080` is fine. **Fallback — only if the sign-in callback later fails**
> (e.g. `AADSTS50011` in Step 4c): open the app → **Manage → Authentication** (may show as
> "Authentication (Preview)") and confirm **"Mobile and desktop applications"** lists
> `http://localhost:8080/callback`; if missing, **+ Add a platform → Mobile and desktop
> applications**, enter it, **Configure**. Reach the app via App registrations →
> `https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade` →
> **All applications**.

---

## Step 4 — Authorization (use `connectlocalhost.mjs`)

This is where you use the connect-localhost script to **generate the authorization URL**
and, after the user pastes the localhost callback back, to **exchange the code for
tokens**. The script keeps no state between the two calls — **you** hold the `session`
blob. Because this is a **public client, there is no client secret** anywhere in this
flow (PKCE is what proves the request).

### 4a — Generate the auth URL

Run `start` with the Graph scopes and `prompt=consent` (forces the consent screen so all
scopes are granted and a refresh token is issued). Do **not** pass `--resource` — Graph
v2.0 carries the resource in the scopes, not a separate parameter.

```bash
node connectlocalhost.mjs start \
  --authorize-endpoint https://login.microsoftonline.com/common/oauth2/v2.0/authorize \
  --token-endpoint https://login.microsoftonline.com/common/oauth2/v2.0/token \
  --client-id '<client_id>' \
  --port 8080 \
  --scope "openid profile email offline_access User.Read Mail.ReadWrite Mail.Send Calendars.ReadWrite Contacts.ReadWrite Files.ReadWrite.All" \
  --extra prompt=consent
```

(If the user chose a non-`common` tenant in Step 3, swap the tenant segment in **both**
endpoints — see the Step 3 tenant note.)

`start` prints two JSON lines:

- `{"event":"auth_url","url":"https://login.microsoftonline.com/common/oauth2/v2.0/authorize?...","redirect_uri":"http://localhost:8080/callback"}`
  → **relay `url` to the user** (as a copy-paste block — see 4b).
- `{"event":"session", ...}` → **you keep this whole object**; pass it verbatim to
  `finish` in 4c. Do not show it to the user.

### 4b — Relay the auth URL and collect the callback

Send (put the actual `url` from the `auth_url` event inside the code block):

> **Step 4: Authorize access**
>
> Final step! Sign in (if asked) and grant access to Mail, Calendar, Contacts and Files.
>
> Use the same browser. Copy and paste this link:

```
`<auth_url value from the start event — the real https://… URL>`
```

> Review the permissions and click **Accept**.
>
> After accepting, your browser will show a **"This site can't be reached"** error at a
> `localhost` address — that's expected!
>
> Copy the **FULL URL** from your browser's address bar. It should look something like:

```
http://localhost:8080/callback?code=...&state=...
```

> Paste it here. Or type **"Abort"** to cancel.

**Validate the reply:** it must contain `localhost`. If it doesn't but looks like a URL
or long string, nudge:

> That doesn't look like the right URL. It should start with `http://localhost`. After
> clicking **Accept** the page shows a **"This site can't be reached"** error — that's
> normal. Copy the **full URL** from the address bar at that point.

Treat the pasted callback URL as **sensitive** (it carries the auth code) — mark the
user's message for deletion at the end.

### 4c — Exchange the code for tokens

Feed the pasted URL plus the saved `session` to `finish`. A public client sends **no
secret**, so do **not** pass `--client-secret-env`:

```bash
node connectlocalhost.mjs finish \
  --pasted "<full localhost callback URL the user pasted>" \
  --session '<the session JSON from 4a>'
```

The script validates `state` (CSRF guard) before exchanging. It prints:

- `{"event":"credentials","access_token":"...","refresh_token":"...","expires_in":...,"token_type":"Bearer","token_endpoint":"https://login.microsoftonline.com/common/oauth2/v2.0/token","client_id":"...","scopes":[...],...}`

If instead you get `{"event":"error",...}`:

- `STATE_MISMATCH` → the pasted URL is from a different attempt; re-send the auth URL.
- `OAUTH_ERROR` (e.g. `access_denied`) → the user declined, **or** the tenant requires
  **admin consent** for a scope (the error mentions admin approval / `AADSTS65001`). If
  it's a managed work tenant, have an admin grant consent (or drop the high-impact scope
  like `Mail.Send` and retry); for a personal account this shouldn't happen.
- `EXCHANGE_FAILED` with `AADSTS50011` (redirect mismatch) → the redirect URI doesn't match
  exactly; re-check (Step 3 / Authentication) that it is `http://localhost:8080/callback`
  under **Mobile and desktop applications**.
- `EXCHANGE_FAILED` with `AADSTS7000218` (expects client secret) → the redirect platform is
  likely **Web** instead of **Mobile and desktop applications** — re-add it via **Manage →
  Authentication** as the public platform. If it persists, open **Authentication → Advanced
  settings** and set **"Allow public client flows"** to **Yes** (only needed in this case;
  skip it otherwise).

> **Refresh token required.** If `refresh_token` is `null`, `offline_access` didn't take.
> Re-run 4a–4c with `offline_access` present in `--scope` and `--extra prompt=consent`.

### 4d — Get the account email

The connected account's address isn't in the token response — fetch it from Graph with
the access token (keeps the Bearer token out of the process arg list):

```bash
printf 'header = "Authorization: Bearer %s"\n' "<access_token>" \
  | curl -s -K - 'https://graph.microsoft.com/v1.0/me?$select=mail,userPrincipalName,displayName'
```

Read `.mail` if non-null, otherwise `.userPrincipalName` (personal accounts often have a
null `mail` and an awkward UPN — prefer `mail` when present). If both are empty, the token
is bad — restart Step 4. Confirm: *"Step 4 complete — authorized for `<email>`."* (You
store the credentials in the next section.)

---

## Storing the credentials

Store the result **per `storingsecrets.md`** — *you* (Claude) store it; the scripts never
write to disk. The `finish` event gives you `access_token`, `refresh_token`, `client_id`,
`token_endpoint`, `scopes`; add the `<email>` from 4d and the tenant segment you used.
**Nothing is committed; `.env` is `chmod 600`. There is no client secret to store.**

An OAuth credential is several values, so keep them together by **sharing one prefix** —
the prefix *is* the index. This is always the **user's own** Microsoft account, so it
takes the **`USER_`** owner prefix (`storingsecrets.md` §4) — read-only by default, write
only when the user asks. (There is no agent-owned Microsoft account here; an agent-owned
account is a Google Workspace account — see `googleworkspaceoauth.md` and the scope note
at the top of this runbook.)

So, `USER_MICROSOFT_365_RW`:

```
# .env  (chmod 600, never committed)
USER_MICROSOFT_365_RW_ACCESS_TOKEN=eyJ0...                                            # secret
USER_MICROSOFT_365_RW_REFRESH_TOKEN=0.AXo...                                          # secret
USER_MICROSOFT_365_RW_CLIENT_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx                  # non-secret (public client id)
USER_MICROSOFT_365_RW_TOKEN_ENDPOINT=https://login.microsoftonline.com/common/oauth2/v2.0/token   # non-secret
USER_MICROSOFT_365_RW_SCOPES='openid profile email offline_access User.Read Mail.ReadWrite Mail.Send Calendars.ReadWrite Contacts.ReadWrite Files.ReadWrite.All'  # non-secret — quote it (spaces)
USER_MICROSOFT_365_RW_EMAIL=<email>                                                   # non-secret: the connected account
```

> **Quote `USER_MICROSOFT_365_RW_SCOPES`.** OAuth scopes are a **space-separated** list.
> When a `.env` is loaded by shell-`source`ing it, an unquoted `KEY=a b c` is parsed as
> "run command `b` with `KEY=a` in its env" — truncating the value and possibly aborting
> the load. **Single-quote the whole value** (as shown). This is the only field with
> spaces; the rest are single tokens (see `storingsecrets.md` §1).

> **No `CLIENT_SECRET`.** Unlike a confidential client (e.g. the Google Workspace Desktop
> client), this is a **public** client — PKCE replaces the secret, so there is no
> `_CLIENT_SECRET` var. The `client_id` is **not** a secret.

To act on the account, read the access token from `USER_MICROSOFT_365_RW_ACCESS_TOKEN`; to
refresh, read the sibling vars under the `USER_MICROSOFT_365_RW_` prefix and call
`refresh.mjs` (see below).

---

## Connection tests (recommended)

Confirm the credentials actually work before declaring success. **This is the user's LIVE
account — run READ-ONLY tests only. Never send mail, create events, or write/delete files
during testing.** Tell the user *"Credentials stored ✅ — now testing them by reading from
your account (read-only)…"*, then with the access token make these **read-only** Graph calls (base `https://graph.microsoft.com/v1.0`, header
`Authorization: Bearer <access_token>`):

| Test | Call (read-only) | Expect |
|---|---|---|
| Read profile | `GET /me` | 200 |
| Read mail | `GET /me/messages?$top=1` | 200 |
| Read calendar | `GET /me/events?$top=1` | 200 |
| Read files | `GET /me/drive/root/children?$top=1` | 200 |
| Read contacts | `GET /me/contacts?$top=1` | 200 |

All are `GET`s — they only confirm the token + scopes work, and **change nothing** in the
account. (A `2xx` proves the matching write scope was also granted, since the read and write
scopes are requested together; we deliberately do **not** exercise the write paths on a live
account.) Report a tally, e.g.:

> Test Results
>
> Passed: 5/5
> ✅ Read profile
> ✅ Read mail
> ✅ Read calendar
> ✅ Read files
> ✅ Read contacts
>
> You're all set! (I tested read-only — I didn't send, create, or change anything.)

If a test fails, surface the HTTP status — a `403`/`AADSTS` usually means a scope wasn't
granted in Step 4 (re-run with `prompt=consent`), and a `401` means the access token
expired (refresh it, below).

---

## Cleaning up sensitive messages

Before finishing, **delete the sensitive messages** from the chat history:

- the user's message containing the **localhost callback URL** (Step 4b — carries the
  auth code),
- the **auth-URL message** you sent (contains the `client_id`).

(The Application (client) ID from Step 3 is **not** a secret, but delete it too if you
prefer a clean thread.) On Telegram, delete each by `message_id` (track them as they
arrive). Then confirm:

> ✅ Setup complete! Sensitive messages have been automatically deleted from the chat.

---

## Finishing up

Send a closing message (and reload/restart the harness if anything consumes the new
`.env` bundle at startup):

> `<email>` is connected. I can now read and send mail, manage your calendar and
> contacts, and read/write your OneDrive files for this account.

---

## Later: refreshing the access token

Access tokens expire (~1 hour). Refresh without re-signing-in using the stored refresh
token (a public client needs **no** client secret — omit `--client-secret-env`):

```bash
USER_MICROSOFT_365_RW_REFRESH_TOKEN='0.AXo...' \
node refresh.mjs \
  --token-endpoint https://login.microsoftonline.com/common/oauth2/v2.0/token \
  --client-id '<client_id>' \
  --scope "openid profile email offline_access User.Read Mail.ReadWrite Mail.Send Calendars.ReadWrite Contacts.ReadWrite Files.ReadWrite.All" \
  --refresh-token-env USER_MICROSOFT_365_RW_REFRESH_TOKEN
```

It emits a fresh `credentials` event — overwrite `USER_MICROSOFT_365_RW_ACCESS_TOKEN` with
the new `access_token`.

> **Microsoft rotates the refresh token on every redemption.** If the response carries a
> new `refresh_token`, you **must** overwrite `USER_MICROSOFT_365_RW_REFRESH_TOKEN` with it
> (the old one stops working). `refresh.mjs` returns the rotated token when present, else
> the one you passed in. (Register as **Mobile/desktop**, not SPA — SPA refresh tokens are
> capped at 24h; native/desktop public-client refresh tokens last up to 90 days of
> inactivity.)

---

## Abort & error handling (any step)

- **"Abort"** at any prompt → stop immediately, delete sensitive messages, tell the user
  it's cancelled. Don't send further validation errors after an abort.
- **No reply for a long time** → it's fine to wait; re-prompt gently rather than
  abandoning.
- **Wrong client ID / redirect / callback URL** → re-ask with the specific correction
  message above; never guess on the user's behalf.
- **`AADSTS` errors** → see the 4c troubleshooting list (admin consent, redirect mismatch,
  wrong platform type).
