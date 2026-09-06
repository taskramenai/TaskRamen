# Connecting Google Ads (read-only, the user's own Ads account)

A **Claude-driven** runbook for connecting a user's **own Google Ads account** so a
Claude harness can read it (list campaigns, pull performance) via the **Google Ads
API**. It corresponds to **connectorskill.md → "Google Ads → OAuth with localhost
(Desktop client + Ads API)"**.

This is the headless, conversational replacement for a setup script: **Claude reads
this file and runs the flow itself**, talking the user through it one message at a
time and using `connectlocalhost.mjs` for the authorization URL + token exchange (the
same OAuth-with-localhost machinery as `googleworkspaceoauth.md`).

> **This is the user's EXISTING Google account** — the one that already manages their
> Google Ads campaigns. Unlike `googleworkspaceoauth.md` (a brand-new dedicated
> account in incognito), here the user stays signed into their **real** Google
> account throughout, because that is the account that owns the Ads data. We request
> only what's needed and **only ever read** (Step 9 is read-only; never mutate).

At the end of a successful run you will have stored (per `storingsecrets.md`, in the
`USER_GOOGLE_ADS_RW_` bundle):

```
USER_GOOGLE_ADS_RW_DEVELOPER_TOKEN      # secret  — Google Ads API developer token
USER_GOOGLE_ADS_RW_CLIENT_ID            # non-secret
USER_GOOGLE_ADS_RW_CLIENT_SECRET        # secret
USER_GOOGLE_ADS_RW_REFRESH_TOKEN        # secret
USER_GOOGLE_ADS_RW_ACCESS_TOKEN         # secret  (short-lived; refreshed from the above)
USER_GOOGLE_ADS_RW_TOKEN_ENDPOINT       # non-secret
USER_GOOGLE_ADS_RW_SCOPES               # non-secret
USER_GOOGLE_ADS_RW_LOGIN_CUSTOMER_ID    # non-secret — the Manager (MCC) account id, digits only
```

---

## Ground rules for Claude (read before starting)

- **Run interactively — never as a background / fire-and-forget job.** This flow
  needs the user's replies between steps (the Manager account number, the developer
  token, pasted `client_id`/`client_secret`, the pasted localhost callback). Drive it
  in a session that can receive those replies; a detached/background agent that only
  reports on completion will hang.
- **Drive it yourself, one step at a time.** Assume the user is **non-technical**.
  Send **one step**, **wait for "Done"/the value** before the next, keep each message
  short. Do not dump all the steps at once.
- **The liability waiver is a hard gate.** Do **not** proceed past the waiver
  (Step 0b) until the user types **"Agree"**. If they type **"Abort"** at any point,
  stop, delete any sensitive messages, and return.
- **Follow the messages and URLs below as written.** The links are battle-tested —
  reproduce them faithfully. Do not invent extra steps or reorder them.
- **Never store secrets in the repo.** The developer token, client secret, tokens,
  and the auth callback URL are sensitive. Store them per "Storing the credentials"
  below (`chmod 600`), never committed.
- **The user works in ONE browser signed into the Google account that manages their
  Google Ads** — every console link is opened in that same window so the developer
  token, project, and OAuth client all attach to the right account. (This is the
  opposite of the workspace runbook's incognito rule — here we *want* their real,
  already-signed-in account.)
- **This is a read-only integration.** The `adwords` OAuth scope is the only scope
  Google Ads offers and it is read+write capable, hence the `RW` bundle name — but
  this harness must only ever issue **read** calls (`search`/`searchStream`,
  `listAccessibleCustomers`). Never send a mutate.

### Relaying URLs over chat

Every URL must be **tap-to-copy, not clickable**: the user copies it and pastes it
into the browser that is signed into their Google Ads account. A tap opens the chat
app's in-app browser, which hides your instructions, may be signed into the wrong
account, and breaks the localhost callback. Tell them the first time: *"Copy this
link and paste it into the browser where you're signed into Google Ads — don't tap
it."*

**How (Telegram):** send the URL on its own, wrapped in single backticks, with
`format: "markdownv2"` — that makes it tap-to-copy and a URL inside backticks needs
no escaping. Keep your prose in separate replies. Full rule + self-check:
`connectorskill.md` → "RELAYING LINKS OVER CHAT". Everywhere below, the URL shown in
a `code block` already includes the backticks — that block **is** the literal `text`
payload.

---

## What gets connected

**API enabled** (Step 4): `googleads.googleapis.com`

**OAuth scope requested** (Step 8): `https://www.googleapis.com/auth/adwords`
(the single Google Ads API scope).

---

## Step 0 — Explain, warn, and locate the user in the process

### 0a — The Explorer-vs-Test warning (send BEFORE starting)

Send this up front so the user understands the one thing that can stall the whole
process:

> Heads up before we start. When you apply for a Google Ads **developer token**,
> Google decides on the spot which **one of two** things to give you:
>
> • an **Explorer access** token — you can use your **real** Google Ads account right
>   away, or
> • a **Test access** token — you **cannot** use it on real accounts. Your only way
>   forward is to apply separately for **Basic access**, which **is never granted on
>   the spot**: Google reviews the application and approval can take days.
>
> So the goal at this stage is to be handed an **Explorer** token directly — that's
> the only outcome that lets us connect today. To maximise that chance:
> 1. Use a Google account with an **active Google Ads account** you've been spending
>    on consistently over time.
> 2. When the form asks, fill in your **real company name** and **company website**,
>    matching the ones on that Google Ads account.
> 3. Make sure your browser is **signed in with the same Google account** you use to
>    manage Google Ads.
>
> I'll ask you to confirm **"Done"** after each step. Ready? Reply **"yes"** to begin
> (or **"no"** to cancel).

Wait for **"yes"**.

### 0b — Liability waiver (HARD GATE)

Once they've said "yes", send this **verbatim** and do **not** proceed until they
type **"Agree"**:

> We will now connect your **real, existing Google Ads** account for use by your AI
> Agent.
>
> **WARNING:** The AI Agent will hold API credentials for this account (a developer
> token + an OAuth refresh token) with **full read AND write access** — that is the
> only access level Google Ads offers, and we **cannot guarantee** the AI Agent will
> never make a mistake. Because of this, you face severe risks, including **data
> loss**, **data leakage**, **unintended changes to your campaigns, budgets, bids, or
> billing**, and **account suspension** by Google (e.g. for automated / bot-like
> activity).
>
> **LIABILITY WAIVER:** By typing "Agree", you accept these risks. To the maximum
> extent permitted by law, you agree to release, hold harmless, and fully indemnify
> the developers against any claims, losses, or liabilities arising from data loss,
> data leaks, account suspension, unintended spend / billing / campaign changes, or
> any other consequence of granting this access.
>
> Type **"Agree"** to proceed. Type **"Abort"** to stop.

- If the user types **"Agree"** (case-insensitive) → continue to Step 0c.
- If they type **"Abort"** → stop and return.
- Any other reply → re-prompt / keep waiting. **Do not proceed without "Agree".**

### 0c — Check `.env` and figure out where the user already is

Before walking through everything, **read `.env`** (look for any `USER_GOOGLE_ADS_RW_*`
keys) and **ask the user** where they are — people often arrive mid-process. Branch:

| What's already true | Where to start |
|---|---|
| Nothing yet | Step 1 (create Manager account) |
| Has a Manager (MCC) account already | Step 2 (get developer token) — just collect the Manager account id first |
| Already has a **developer token** stored / in hand | Skip Phase 1 → go to **Phase 2, Step 3** (OAuth) |
| Had a **Test** token and has now been granted **Basic access** | Collect/confirm the (now usable) developer token, then go to **Phase 2, Step 3** |
| Has dev token + client id/secret already | Go straight to **Step 8** (run the OAuth exchange) |

Ask plainly, e.g.: *"Do you already have a Google Ads Manager account and/or a
developer token, or are we starting from scratch?"* Then jump to the right step. If a
developer token / Manager id is already in `.env`, confirm it with the user rather
than redoing those steps.

---

# Phase 1 — Manager account + developer token

## Step 1/9 — Create a Google Ads Manager (MCC) account

Send:

> **Step 1: Create a Google Ads Manager account**
>
> In the browser signed into your Google Ads account, copy and paste this link:

```
`https://business.google.com/en-all/ad-tools/manage-accounts/`
```

> 1. Click **"Start Now"** (top-right corner)
> 2. Create a **new** Google Ads **Manager** account
> 3. When asked, choose **"Manage your own account"**
> 4. Once created, find your **Manager account number** (10 digits, shown top-right,
>    like `123-456-7890`)
>
> Reply with the **Manager account number** when you have it. Or type **"Abort"** to
> cancel.

**Validate** the reply: it should be 10 digits (accept the `XXX-XXX-XXXX` dashed
form). Strip everything but digits and require exactly 10 (`^\d{10}$`). If it doesn't
match: *"That doesn't look like a 10-digit Manager account number (like
123-456-7890). Please paste it again."*

Hold the digits-only value as `<manager_id>` — you'll store it as
`USER_GOOGLE_ADS_RW_LOGIN_CUSTOMER_ID` and pass it as the `login-customer-id` header on
every API call. Confirm: *"Got it — Manager account `<manager_id>`."*

## Step 2/9 — Get a developer token from the API Center

Send:

> **Step 2: Get your developer token**
>
> Copy and paste this link (same browser):

```
`https://ads.google.com/aw/apicenter`
```

> 1. It will show a list of accounts — **select the Manager account you just
>    created** in Step 1.
> 2. Fill in the form **accurately** — especially your **company name** and **company
>    website**, matching the ones on your live Google Ads campaign. (This is what
>    maximises your chance of being handed an **Explorer** token directly.)
> 3. **Role:** choose **"Advertiser"** ("Manage it for yourself").
> 4. **Intended use:** write something like *"Analyze our company's own Google Ads
>    account using an AI tool."*
> 5. **Accept** the Terms & Conditions.
> 6. Click **"Accept token"** at the end of the form.
>
> It will then show your access level — it'll be **one of two**: **Explorer** or
> **Test**. Reply with **which one you got**. Or type **"Abort"** to cancel.

Branch on the reply:

- **Explorer** → great, you can use it on the real account immediately. Ask for the
  token:

  > You're good to go. Copy the **developer token** shown on that page and paste it
  > here.

  Treat the token message as **sensitive** (mark it for deletion at cleanup). When
  you have it, confirm *"Developer token received."* and continue to **Phase 2,
  Step 3**.

- **Test access** → you **cannot** proceed yet (a Test token can't touch real
  accounts). Send:

  > You've been given a **Test** token, which can't access your real Google Ads
  > account. The only way forward is to **apply for Basic access** from that same API
  > Center page. **Basic access is never granted immediately** — Google reviews each
  > application, and approval typically takes a few days.
  >
  > **So we have to pause here** — there's nothing I can connect until Google approves
  > Basic access. Once they do, message me the developer token and I'll pick up right
  > from the OAuth step.

  Then **stop** (record where you left off so a later session can resume at Step 3).
  Do not continue the flow.

---

# Phase 2 — OAuth (Desktop client + token exchange)

> From here it mirrors `googleworkspaceoauth.md` Steps 3–5, but with the Google Ads
> API and a single scope. The user uses the **same browser signed into their Google
> Ads account** (not incognito).

## Step 3/9 — Create a Google Cloud project

Send:

> **Step 3: Create a Google Cloud project**
>
> Copy and paste this link (same browser):

```
`https://console.cloud.google.com/projectcreate`
```

> 1. **Project name:** anything (e.g. "Ads Reader")
> 2. Leave the organization/location as-is
> 3. Click **"Create"**
> 4. Wait for it to finish, then make sure the new project is **selected** (top-left
>    dropdown)
>
> Reply **"Done"** when the project is created and selected. Or **"Abort"**.

Wait for **"Done"**.

## Step 4/9 — Enable the Google Ads API

Send:

> **Step 4: Enable the Google Ads API**
>
> Copy and paste this link (same browser, same project):

```
`https://console.cloud.google.com/apis/library/googleads.googleapis.com`
```

> Make sure your new project is selected at the top, then click **"Enable"**.
>
> Reply **"Done"** once it's enabled. Or **"Abort"**.

Wait for **"Done"**.

## Step 5/9 — OAuth consent screen

Send:

> **Step 5: Set up the OAuth consent screen**
>
> Copy and paste this link (same browser, same project):

```
`https://console.cloud.google.com/apis/credentials/consent`
```

> 1. Choose **"External"**
> 2. **App name:** anything (e.g. "Ads Reader") — it doesn't matter
> 3. **User support email / Developer contact email:** your own email
> 4. Click **"Save and Continue"** through the remaining steps
>
> Reply **"Done"** when finished. Or **"Abort"**.

Wait for **"Done"**.

## Step 6/9 — Publish the app (so the token doesn't expire)

Send:

> **Step 6: Publish the app**
>
> This stops your access from expiring after 7 days. It does **not** let anyone else
> access your Google Ads account — it only keeps your own access from expiring.
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

## Step 7/9 — Create the Desktop OAuth client

Send:

> **Step 7: Create credentials (OAuth client)**
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

## Step 8/9 — Run the OAuth flow (use `connectlocalhost.mjs`)

Same two-call, stateless pattern as the workspace runbook: `start` builds the auth
URL and a `session` blob **you** hold; `finish` exchanges the pasted callback for
tokens.

### 8a — Generate the auth URL

```bash
node connectlocalhost.mjs start \
  --authorize-endpoint https://accounts.google.com/o/oauth2/v2/auth \
  --token-endpoint https://oauth2.googleapis.com/token \
  --client-id '<client_id>' \
  --port 8080 \
  --scope "https://www.googleapis.com/auth/adwords" \
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

### 8b — Relay the auth URL and collect the callback

Send (put the real `url` from the `auth_url` event inside the code block):

> **Step 8: Authorize access to your Google Ads data**
>
> Final connection step. Use the **same browser signed into your Google Ads
> account**. Copy and paste this link:

```
`<auth_url value from the start event — the real https://… URL>`
```

> 1. Pick the Google account that manages your Google Ads (if asked).
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

### 8c — Exchange the code for tokens

Pass the client secret via env var (never argv):

```bash
USER_GOOGLE_ADS_RW_CLIENT_SECRET='<client_secret>' \
node connectlocalhost.mjs finish \
  --pasted "<full localhost callback URL the user pasted>" \
  --session '<the session JSON from 8a>' \
  --client-secret-env USER_GOOGLE_ADS_RW_CLIENT_SECRET
```

It prints `{"event":"credentials","access_token":"...","refresh_token":"...","client_id":"...","token_endpoint":"...","scopes":[...]}`.

On `{"event":"error",...}`:
- `STATE_MISMATCH` → pasted URL is from a different attempt; re-send the auth URL.
- `OAUTH_ERROR` (`access_denied`) → user declined; redo Step 8b and click **Allow**.
- `EXCHANGE_FAILED` → wrong/expired code or bad client secret; restart Step 8.

> **Refresh token required.** If `refresh_token` is `null`, the offline/consent flags
> didn't take. Re-run 8a–8c — Google only returns a refresh token with both
> `access_type=offline` **and** `prompt=consent` and a fresh consent.

---

## Storing the credentials

Store the result **per `storingsecrets.md`** in the `USER_GOOGLE_ADS_RW_` OAuth bundle —
*you* (Claude) store it; the scripts never write to disk. **Nothing is committed;
`.env` is `chmod 600`.**

```
# .env  (chmod 600, never committed)
USER_GOOGLE_ADS_RW_DEVELOPER_TOKEN=<developer token from Step 2>                # secret
USER_GOOGLE_ADS_RW_ACCESS_TOKEN=ya29....                                       # secret
USER_GOOGLE_ADS_RW_REFRESH_TOKEN=1//....                                       # secret
USER_GOOGLE_ADS_RW_CLIENT_SECRET=GOCSPX-...                                    # secret
USER_GOOGLE_ADS_RW_CLIENT_ID=...apps.googleusercontent.com                    # non-secret
USER_GOOGLE_ADS_RW_TOKEN_ENDPOINT=https://oauth2.googleapis.com/token         # non-secret
USER_GOOGLE_ADS_RW_SCOPES='https://www.googleapis.com/auth/adwords'           # non-secret
USER_GOOGLE_ADS_RW_LOGIN_CUSTOMER_ID=<manager_id, digits only>               # non-secret
```

- **`USER_` prefix = the user's own account** (not the agent's `SERVICE_` account) —
  this is what keeps the user's Google Ads from being confused with the agent's own
  service credentials (`storingsecrets.md` §4). Read-only by default; never mutate.
- **One secret per var; the name is the index** — `USER_GOOGLE_ADS_RW_*` already says
  "the user's Google Ads, this account." Read `USER_GOOGLE_ADS_RW_ACCESS_TOKEN` to call
  the API; refresh from the sibling vars under the same prefix (see "refreshing" below).
- **Quote `USER_GOOGLE_ADS_RW_SCOPES`** even though it's a single scope today — it's an
  OAuth scope field and quoting keeps shell-`source` safe (`storingsecrets.md` §1).
- The **developer token** and **login-customer-id** are Ads-specific extras that the
  OAuth `credentials` event doesn't carry — add them from Step 2 and Step 1. The
  developer token is a **secret**; the Manager id is not.

After writing, `chmod 600 .env`.

---

## Step 9/9 — Connection test (READ ONLY — list campaigns)

Confirm it works before declaring success. Tell the user *"Credentials stored ✅ — now
testing them by reading: I'll list your campaigns (read-only)."* Then, with `set -a; source .env; set +a` to load the
bundle:

**1) Find the accounts you can read** (which production account is under the
Manager):

```bash
curl -s "https://googleads.googleapis.com/v19/customers:listAccessibleCustomers" \
  -H "Authorization: Bearer $USER_GOOGLE_ADS_RW_ACCESS_TOKEN" \
  -H "developer-token: $USER_GOOGLE_ADS_RW_DEVELOPER_TOKEN"
```

> Use the **current stable** Google Ads API version in the path (e.g. `v19`/`v20`); if
> you get a 404/`UNSUPPORTED_VERSION`, bump the version number. If you get **401**,
> refresh the access token first (see below) and retry. **403 /
> `DEVELOPER_TOKEN_NOT_APPROVED`** means you still have a Test token — the user must
> get Basic access (back to Step 2).

This returns `resourceNames: ["customers/1234567890", ...]`. These are the accounts
the user can access. If there are several and it's unclear which is the live ad
account, ask the user which one to report on.

**2) List that account's campaigns** (read-only `searchStream`), passing the Manager
id as `login-customer-id` and the chosen client account id as `<customer_id>`
(digits only):

```bash
curl -s -X POST \
  "https://googleads.googleapis.com/v19/customers/<customer_id>/googleAds:searchStream" \
  -H "Authorization: Bearer $USER_GOOGLE_ADS_RW_ACCESS_TOKEN" \
  -H "developer-token: $USER_GOOGLE_ADS_RW_DEVELOPER_TOKEN" \
  -H "login-customer-id: $USER_GOOGLE_ADS_RW_LOGIN_CUSTOMER_ID" \
  -H "Content-Type: application/json" \
  -d '{"query":"SELECT campaign.id, campaign.name, campaign.status FROM campaign ORDER BY campaign.id LIMIT 50"}'
```

Parse the JSON and report the campaigns to the user, e.g.:

> ✅ Connected to Google Ads. I can read account `<customer_id>`. Your campaigns:
> • <name> — <status>
> • …
>
> You're all set. I'll only ever **read** this account — never make changes.

If a call fails, surface the HTTP status + error so the cause is visible (401 → token
expired/refresh; 403 → token not approved / wrong `login-customer-id`; 404 → wrong
API version). **Never run a mutate to "test write"** — this integration is read-only.

---

## Cleaning up sensitive messages

Before finishing, **delete the sensitive messages** from the chat:

- the user's message containing the **developer token** (Step 2),
- the user's message(s) containing the **Client ID / Client Secret** (Step 7),
- the user's message containing the **localhost callback URL** (Step 8b, carries the
  auth code),
- the **auth-URL message** you sent (contains the `client_id`).

On Telegram, delete each by `message_id` (track them as they arrive). Then confirm:

> ✅ Setup complete! Sensitive messages have been deleted from the chat.

---

## Later: refreshing the access token

Access tokens expire (~1 hour). Refresh without re-signing-in using the stored
refresh token + client secret (both from env, never argv):

```bash
USER_GOOGLE_ADS_RW_REFRESH_TOKEN='1//...' USER_GOOGLE_ADS_RW_CLIENT_SECRET='GOCSPX-...' \
node refresh.mjs \
  --token-endpoint https://oauth2.googleapis.com/token \
  --client-id '<client_id>' \
  --refresh-token-env USER_GOOGLE_ADS_RW_REFRESH_TOKEN \
  --client-secret-env USER_GOOGLE_ADS_RW_CLIENT_SECRET
```

It emits a fresh `credentials` event — overwrite `USER_GOOGLE_ADS_RW_ACCESS_TOKEN` with
the new `access_token`, and if a rotated `refresh_token` came back, overwrite
`USER_GOOGLE_ADS_RW_REFRESH_TOKEN` too. The developer token, client id, scopes, and
Manager id are unchanged.

---

## Abort & error handling (any step)

- **"Abort"** at any prompt → stop immediately, delete sensitive messages, tell the
  user it's cancelled.
- **Test token instead of an Explorer token** → this is a hard stop (Step 2). Basic
  access is never granted on the spot, so pause and resume at Step 3 only after Google
  approves the Basic access application.
- **No reply for a long time** → it's fine to wait; re-prompt gently rather than
  abandoning.
- **Wrong Manager number / client values / callback URL** → re-ask with the specific
  correction message above; never guess on the user's behalf.
- **403 `DEVELOPER_TOKEN_NOT_APPROVED` during the test** → the token is still
  Test-level; the user must complete Basic access before the integration can read a
  real account.
