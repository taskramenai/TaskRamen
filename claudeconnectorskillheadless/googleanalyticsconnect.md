# Connecting Google Analytics (GA4) — read-only, the user's own account

A **Claude-driven** runbook for connecting a user's **own Google Analytics (GA4)**
account so a Claude harness can read it (list properties, pull reports) via the
**Analytics Admin + Data APIs**. It corresponds to **connectorskill.md → "Google
Analytics (GA4) → OAuth with localhost"**.

This is the headless, conversational replacement for a setup script: **Claude reads
this file and runs the flow itself**, talking the user through it one message at a
time and using `connectlocalhost.mjs` for the authorization URL + token exchange (the
**same OAuth-with-localhost machinery as `googleadsconnect.md` / `googleworkspaceoauth.md`**).

> **This is the user's EXISTING Google account** — the one that already has access to
> their Analytics property. Unlike `googleworkspaceoauth.md` (a brand-new dedicated
> account in incognito), here the user stays signed into their **real** Google
> account throughout, because that is the account that owns the Analytics data.
>
> **It's just OAuth.** Unlike Google Ads, GA4 needs **no developer token and no
> manager account** — only the OAuth steps. The scope requested is **read-only**.

At the end of a successful run you will have stored (per `storingsecrets.md`, in the
`USER_GOOGLE_ANALYTICS_RO_` bundle):

```
USER_GOOGLE_ANALYTICS_RO_CLIENT_ID            # non-secret
USER_GOOGLE_ANALYTICS_RO_CLIENT_SECRET        # secret
USER_GOOGLE_ANALYTICS_RO_REFRESH_TOKEN        # secret
USER_GOOGLE_ANALYTICS_RO_ACCESS_TOKEN         # secret  (short-lived; refreshed from the above)
USER_GOOGLE_ANALYTICS_RO_TOKEN_ENDPOINT       # non-secret
USER_GOOGLE_ANALYTICS_RO_SCOPES               # non-secret
```

---

## Ground rules for Claude (read before starting)

- **Run interactively — never as a background / fire-and-forget job.** This flow
  needs the user's replies between steps (pasted `client_id`/`client_secret`, the
  pasted localhost callback). Drive it in a session that can receive those replies; a
  detached/background agent that only reports on completion will hang.
- **Drive it yourself, one step at a time.** Assume the user is **non-technical**.
  Send **one step**, **wait for "Done"/the value** before the next, keep each message
  short. Do not dump all the steps at once.
- **The liability waiver is a hard gate.** Do **not** proceed past the waiver
  (Step 0b) until the user types **"Agree"**. If they type **"Abort"** at any point,
  stop, delete any sensitive messages, and return.
- **Follow the messages and URLs below as written.** The links are battle-tested —
  reproduce them faithfully. Do not invent extra steps or reorder them.
- **Never store secrets in the repo.** The client secret, tokens, and the auth
  callback URL are sensitive. Store them per "Storing the credentials" below
  (`chmod 600`), never committed.
- **The user works in ONE browser signed into the Google account that has access to
  their Analytics** — every console link is opened in that same window so the project
  and OAuth client attach to the right account. (This is the opposite of the workspace
  runbook's incognito rule — here we *want* their real, already-signed-in account.)
- **This is a read-only integration.** The requested scope
  `https://www.googleapis.com/auth/analytics.readonly` cannot modify anything — and
  the harness should still only ever issue **read** calls (`accountSummaries`,
  `runReport`). Never request a broader scope or attempt a write.

### Relaying URLs over chat

Every URL must be **tap-to-copy, not clickable**: the user copies it and pastes it
into the browser that is signed into their Google account. A tap opens the chat app's
in-app browser, which hides your instructions, may be signed into the wrong account,
and breaks the localhost callback. Tell them the first time: *"Copy this link and
paste it into the browser where you're signed into Google Analytics — don't tap it."*

**How (Telegram):** send the URL on its own, wrapped in single backticks, with
`format: "markdownv2"` — that makes it tap-to-copy and a URL inside backticks needs
no escaping. Keep your prose in separate replies. Full rule + self-check:
`connectorskill.md` → "RELAYING LINKS OVER CHAT". Everywhere below, the URL shown in
a `code block` already includes the backticks — that block **is** the literal `text`
payload.

---

## What gets connected

**APIs enabled** (Steps 2 & 3, as **separate** steps):
`analyticsdata.googleapis.com` (Analytics Data API) and
`analyticsadmin.googleapis.com` (Analytics Admin API).

**OAuth scope requested** (Step 7): `https://www.googleapis.com/auth/analytics.readonly`
(the read-only Google Analytics scope — covers both Admin reads and Data reports).

---

## Step 0 — Explain, confirm, and locate the user in the process

### 0a — Confirm and start

Send:

> I'll connect your **Google Analytics (GA4)** account so I can read your reports
> (properties, traffic, conversions, etc.). This is **read-only** — I'll never change
> anything.
>
> It takes about **10 minutes** and I'll guide you one step at a time. Two things to
> have ready:
> 1. Be **signed in to the Google account** that has access to your Analytics
>    property, in one browser.
> 2. You'll do a few clicks in the Google Cloud Console — I'll give you each link.
>
> Reply **"yes"** to begin (or **"no"** to cancel).

Wait for **"yes"**.

### 0b — Liability waiver (HARD GATE)

Once they've said "yes", send this **verbatim** and do **not** proceed until they
type **"Agree"**:

> We will now connect your **real, existing Google Analytics** account for use by your
> AI Agent.
>
> **WARNING:** The AI Agent will hold OAuth credentials (a refresh token) granting
> **read access to all of your Google Analytics data**, and we **cannot guarantee**
> the AI Agent will never make a mistake or that the data stays fully secure. Because
> of this, you face real risks, including **data leakage / exposure of your analytics
> data** and **account suspension** by Google (e.g. for automated / bot-like
> activity).
>
> **LIABILITY WAIVER:** By typing "Agree", you accept these risks. To the maximum
> extent permitted by law, you agree to release, hold harmless, and fully indemnify
> the developers against any claims, losses, or liabilities arising from data loss,
> data leaks, account suspension, or any other consequence of granting this access.
>
> Type **"Agree"** to proceed. Type **"Abort"** to stop.

- If the user types **"Agree"** (case-insensitive) → continue to Step 0c.
- If they type **"Abort"** → stop and return.
- Any other reply → re-prompt / keep waiting. **Do not proceed without "Agree".**

### 0c — Check `.env` and figure out where the user already is

Before walking through everything, **read `.env`** (look for any
`USER_GOOGLE_ANALYTICS_RO_*` keys) and **ask the user** where they are — people often
arrive mid-process. Branch:

| What's already true | Where to start |
|---|---|
| Nothing yet | Step 1 (create Cloud project) |
| Has a Cloud project, **both** Analytics APIs enabled | Step 4 (OAuth consent screen) |
| Has a Desktop **Client ID + Client Secret** already | Step 7 (run the OAuth exchange) |
| Full bundle already in `.env` | Skip to Step 8 (connection test) and confirm it works |

Ask plainly, e.g.: *"Have you already set up a Google Cloud project for this, or are
we starting from scratch?"* Then jump to the right step.

---

## Step 1/8 — Create a Google Cloud project

Send:

> **Step 1: Create a Google Cloud project**
>
> Copy and paste this link (in the browser signed into your Google account):

```
`https://console.cloud.google.com/projectcreate`
```

> 1. **Project name:** anything (e.g. "Analytics Reader")
> 2. Leave the organization/location as-is
> 3. Click **"Create"**
> 4. Wait for it to finish, then make sure the new project is **selected** (top-left
>    dropdown)
>
> Reply **"Done"** when the project is created and selected. Or **"Abort"**.

Wait for **"Done"**.

## Step 2/8 — Enable the Analytics Data API

Send:

> **Step 2: Enable the Analytics Data API**
>
> Copy and paste this link (same browser, same project):

```
`https://console.cloud.google.com/apis/library/analyticsdata.googleapis.com`
```

> Make sure your new project is selected at the top, then click **"Enable"**.
>
> Reply **"Done"** once it's enabled. Or **"Abort"**.

Wait for **"Done"**.

## Step 3/8 — Enable the Analytics Admin API

Send:

> **Step 3: Enable the Analytics Admin API**
>
> Copy and paste this link (same browser, same project):

```
`https://console.cloud.google.com/apis/library/analyticsadmin.googleapis.com`
```

> Click **"Enable"**.
>
> Reply **"Done"** once it's enabled. Or **"Abort"**.

Wait for **"Done"**.

## Step 4/8 — OAuth consent screen

Send:

> **Step 4: Set up the OAuth consent screen**
>
> Copy and paste this link (same browser, same project):

```
`https://console.cloud.google.com/apis/credentials/consent`
```

> 1. Choose **"External"**
> 2. **App name:** anything (e.g. "Analytics Reader") — it doesn't matter
> 3. **User support email / Developer contact email:** your own email
> 4. Click **"Save and Continue"** through the remaining steps
>
> Reply **"Done"** when finished. Or **"Abort"**.

Wait for **"Done"**.

## Step 5/8 — Publish the app (so the token doesn't expire)

Send:

> **Step 5: Publish the app**
>
> This stops your access from expiring after 7 days. It does **not** let anyone else
> access your account — it only keeps your own access from expiring.
>
> Copy and paste this link (same browser, same project):

```
`https://console.cloud.google.com/auth/audience`
```

> 1. You should see **"Publishing status: Testing"**
> 2. Click **"Publish app"** and confirm
> 3. Status should change to **"In production"**
>
> Reply **"Done"** when the status reads "In production". Or **"Abort"**.

Wait for **"Done"**.

## Step 6/8 — Create the Desktop OAuth client

Send:

> **Step 6: Create credentials (OAuth client)**
>
> Copy and paste this link (same browser, same project):

```
`https://console.cloud.google.com/apis/credentials/oauthclient`
```

> 1. **Application type:** choose **"Desktop app"**
> 2. **Name:** anything (e.g. "Desktop Client 1")
> 3. Click **"Create"**
> 4. A popup shows your **Client ID** and **Client Secret** — copy **both**.
>
> Paste both **Client ID** and **Client Secret** here (one message or two). Or
> **"Abort"**.
>
> **IMPORTANT:** The Client Secret is shown only **once**. If you close the popup
> before copying it, just open the link again and create another client.

**Parsing the reply.** The user may paste raw JSON, `key: value` lines, or two bare
strings. Extract:

- **Client ID** — ends with `.apps.googleusercontent.com`.
- **Client Secret** — starts with `GOCSPX-`.

Tolerate JSON (`{"installed": {...}}`), `client_id:`/`client_secret:` patterns, and
strip invisible Unicode (zero-width spaces, BOM, directional marks) from mobile copy/
paste. If only one value arrived, ask for the other. When you have **both**, confirm
*"Credentials received."* and treat those messages as **sensitive** (mark for
deletion; never echo the secret back).

## Step 7/8 — Run the OAuth flow (use `connectlocalhost.mjs`)

Same two-call, stateless pattern as the other Google runbooks: `start` builds the
auth URL and a `session` blob **you** hold; `finish` exchanges the pasted callback for
tokens.

### 7a — Generate the auth URL

```bash
node connectlocalhost.mjs start \
  --authorize-endpoint https://accounts.google.com/o/oauth2/v2/auth \
  --token-endpoint https://oauth2.googleapis.com/token \
  --client-id '<client_id>' \
  --port 8080 \
  --scope "https://www.googleapis.com/auth/analytics.readonly" \
  --extra access_type=offline \
  --extra prompt=consent
```

Why the flags:
- `--authorize-endpoint` / `--token-endpoint` — Google's fixed OAuth endpoints.
- `--port 8080` — redirect becomes `http://localhost:8080/callback`; a **Desktop**
  client accepts any loopback port.
- `--extra access_type=offline` — **required** so Google returns a **refresh token**.
- `--extra prompt=consent` — forces consent so the refresh token is issued reliably.

`start` prints two JSON lines:
- `{"event":"auth_url","url":"https://accounts.google.com/o/oauth2/v2/auth?...","redirect_uri":"http://localhost:8080/callback"}`
  → **relay `url` to the user** (copy-paste block).
- `{"event":"session", ...}` → **keep this whole object**; pass it verbatim to
  `finish`. Do not show it to the user.

### 7b — Relay the auth URL and collect the callback

Send (put the real `url` from the `auth_url` event inside the code block):

> **Step 7: Authorize read access to your Google Analytics**
>
> Final connection step. Use the **same browser signed into your Google account**.
> Copy and paste this link:

```
`<auth_url value from the start event — the real https://… URL>`
```

> 1. Pick the Google account that has access to your Analytics (if asked).
> 2. You'll see a warning that the app is **unverified** — that's fine, it's the app
>    you just created. Click **"Continue"/"Advanced" → "Go to … (unsafe)"** if shown.
> 3. **Allow** the requested access.
> 4. Your browser will then show a **"This site can't be reached"** error — that's
>    expected!
>
> Copy the **FULL URL** from your browser's address bar (it looks like
> `http://localhost:8080/callback?state=...&code=...`) and paste it here. Or
> **"Abort"**.

**Validate the reply:** it must contain `localhost`. If not, nudge: *"That doesn't
look right — it should start with `http://localhost`. After you click Allow the page
shows a 'can't be reached' error; copy the full URL from the address bar at that
point."* Treat the pasted URL as **sensitive** (it carries the auth code) — mark for
deletion.

### 7c — Exchange the code for tokens

Pass the client secret via env var (never argv):

```bash
USER_GOOGLE_ANALYTICS_RO_CLIENT_SECRET='<client_secret>' \
node connectlocalhost.mjs finish \
  --pasted "<full localhost callback URL the user pasted>" \
  --session '<the session JSON from 7a>' \
  --client-secret-env USER_GOOGLE_ANALYTICS_RO_CLIENT_SECRET
```

It prints `{"event":"credentials","access_token":"...","refresh_token":"...","client_id":"...","token_endpoint":"...","scopes":[...]}`.

On `{"event":"error",...}`:
- `STATE_MISMATCH` → pasted URL is from a different attempt; re-send the auth URL.
- `OAUTH_ERROR` (`access_denied`) → user declined; redo Step 7b and click **Allow**.
- `EXCHANGE_FAILED` → wrong/expired code or bad client secret; restart Step 7.

> **Refresh token required.** If `refresh_token` is `null`, the offline/consent flags
> didn't take. Re-run 7a–7c — Google only returns a refresh token with both
> `access_type=offline` **and** `prompt=consent` and a fresh consent.

---

## Storing the credentials

Store the result **per `storingsecrets.md`** in the `USER_GOOGLE_ANALYTICS_RO_` OAuth
bundle — *you* (Claude) store it; the scripts never write to disk. **Nothing is
committed; `.env` is `chmod 600`.**

```
# .env  (chmod 600, never committed)
USER_GOOGLE_ANALYTICS_RO_ACCESS_TOKEN=ya29....                                       # secret
USER_GOOGLE_ANALYTICS_RO_REFRESH_TOKEN=1//....                                       # secret
USER_GOOGLE_ANALYTICS_RO_CLIENT_SECRET=GOCSPX-...                                    # secret
USER_GOOGLE_ANALYTICS_RO_CLIENT_ID=...apps.googleusercontent.com                    # non-secret
USER_GOOGLE_ANALYTICS_RO_TOKEN_ENDPOINT=https://oauth2.googleapis.com/token         # non-secret
USER_GOOGLE_ANALYTICS_RO_SCOPES='https://www.googleapis.com/auth/analytics.readonly' # non-secret
```

- **`USER_` prefix = the user's own account** (not the agent's `SERVICE_` account) —
  this keeps the user's Analytics from being confused with the agent's own service
  credentials (`storingsecrets.md` §4).
- **`RO` = read-only** — the granted scope (`analytics.readonly`) cannot write, so the
  mode is honestly `RO`, not `RW`.
- **One secret per var; the name is the index** — read
  `USER_GOOGLE_ANALYTICS_RO_ACCESS_TOKEN` to call the API; refresh from the sibling
  vars under the same prefix (see "refreshing" below).
- **Quote `USER_GOOGLE_ANALYTICS_RO_SCOPES`** even though it's a single scope today —
  it's an OAuth scope field and quoting keeps shell-`source` safe (`storingsecrets.md`
  §1).

After writing, `chmod 600 .env`.

---

## Step 8/8 — Connection test (READ ONLY — list properties + sample report)

Confirm it works before declaring success. Tell the user *"Credentials stored ✅ — now
testing them by reading: I'll list your Analytics properties (read-only)."* Then, with `set -a; source .env; set +a` to
load the bundle:

**1) List the accounts & properties you can read** (Admin API):

```bash
curl -s "https://analyticsadmin.googleapis.com/v1beta/accountSummaries" \
  -H "Authorization: Bearer $USER_GOOGLE_ANALYTICS_RO_ACCESS_TOKEN"
```

> If you get **401**, refresh the access token first (see below) and retry. **403 /
> `PERMISSION_DENIED` / `SERVICE_DISABLED`** usually means an API wasn't enabled — go
> back to Steps 2 & 3 and enable both Analytics APIs.

The response lists `accountSummaries[].propertySummaries[]`, each with a `property`
resource name like `properties/123456789` and a `displayName`. If there are several
properties and it's unclear which one to report on, ask the user.

**2) Pull a tiny sample report** for a chosen property (Data API), using the numeric
property id from `properties/<id>`:

```bash
curl -s -X POST \
  "https://analyticsdata.googleapis.com/v1beta/properties/<property_id>:runReport" \
  -H "Authorization: Bearer $USER_GOOGLE_ANALYTICS_RO_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"dateRanges":[{"startDate":"7daysAgo","endDate":"today"}],"metrics":[{"name":"activeUsers"}]}'
```

Parse the JSON and report to the user, e.g.:

> ✅ Connected to Google Analytics. Properties I can read:
> • <displayName> (`properties/<id>`)
> • …
>
> Active users (last 7 days) for <displayName>: **<N>**
>
> You're all set. I'll only ever **read** this account — never make changes.

If a call fails, surface the HTTP status + error so the cause is visible (401 → token
expired/refresh; 403 → an Analytics API not enabled, or the account lacks access to
that property; 404 → wrong property id). **Never attempt a write** — this integration
is read-only.

---

## Cleaning up sensitive messages

Before finishing, **delete the sensitive messages** from the chat:

- the user's message(s) containing the **Client ID / Client Secret** (Step 6),
- the user's message containing the **localhost callback URL** (Step 7b, carries the
  auth code),
- the **auth-URL message** you sent (contains the `client_id`).

On Telegram, delete each by `message_id` (track them as they arrive). Then confirm:

> ✅ Setup complete! Sensitive messages have been deleted from the chat.

---

## Later: refreshing the access token

Access tokens expire (~1 hour). Refresh without re-signing-in using the stored
refresh token + client secret (both from env, never argv):

```bash
USER_GOOGLE_ANALYTICS_RO_REFRESH_TOKEN='1//...' USER_GOOGLE_ANALYTICS_RO_CLIENT_SECRET='GOCSPX-...' \
node refresh.mjs \
  --token-endpoint https://oauth2.googleapis.com/token \
  --client-id '<client_id>' \
  --refresh-token-env USER_GOOGLE_ANALYTICS_RO_REFRESH_TOKEN \
  --client-secret-env USER_GOOGLE_ANALYTICS_RO_CLIENT_SECRET
```

It emits a fresh `credentials` event — overwrite `USER_GOOGLE_ANALYTICS_RO_ACCESS_TOKEN`
with the new `access_token`, and if a rotated `refresh_token` came back, overwrite
`USER_GOOGLE_ANALYTICS_RO_REFRESH_TOKEN` too. The client id and scopes are unchanged.

---

## Abort & error handling (any step)

- **"Abort"** at any prompt → stop immediately, delete sensitive messages, tell the
  user it's cancelled.
- **No reply for a long time** → it's fine to wait; re-prompt gently rather than
  abandoning.
- **Wrong client values / callback URL** → re-ask with the specific correction message
  above; never guess on the user's behalf.
- **403 `SERVICE_DISABLED` during the test** → an Analytics API wasn't enabled; redo
  Steps 2 & 3 (both `analyticsdata` and `analyticsadmin`).
- **403 `PERMISSION_DENIED` on a property** → the signed-in Google account doesn't have
  access to that GA4 property; have the user pick one they can access, or grant access
  in Analytics first.
