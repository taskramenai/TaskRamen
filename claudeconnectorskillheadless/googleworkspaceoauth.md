# Connecting a Google Workspace account (dedicated Claude account)

A **Claude-driven** runbook for connecting a **NEW, DEDICATED** Google Workspace
account (Gmail, Drive, Calendar, Docs, Sheets, Slides, Tasks, Contacts, Forms,
Chat, Apps Script) with **full read/write**, so a Claude harness can act on it as
its *own* account.

This is the headless, conversational replacement for a setup script: **Claude reads
this file and runs the flow itself**, talking the user through it one message at a
time and using `connectlocalhost.mjs` for the authorization URL + token exchange.
It corresponds to **connectorskill.md method #4 (OAuth with localhost)** and to the Google
disambiguation case **(a) Google Workspace as a dedicated Claude account**.

> Use this **only** when the user wants a *separate* Google account that Claude
> owns and fully controls — **not** the user's personal/work Workspace (that is
> case (b), the read-mostly claude.ai connector). If it is not crystal clear which
> Google product is meant, **ask first** (see connectorskill.md "Google — clarify which
> service first").

---

## Ground rules for Claude (read before starting)

- **Run interactively — never as a background / fire-and-forget job.** This flow
  needs the user's replies between steps (waiver, pasted `client_id`/`client_secret`,
  pasted callback URL). Drive it in a session that can receive those replies; a
  detached/background agent that only reports on completion will hang or fail.
- **Drive it yourself, one step at a time.** Assume the user is **non-technical**.
  Send **one step**, **wait for confirmation** before the next, keep each message
  short. Do not dump all five steps at once.
- **Follow the messages and URLs below as written.** The wording, the step order,
  and the URL construction are battle-tested — reproduce them faithfully. Do not
  invent extra steps or reorder them.
- **The liability waiver is a hard gate.** Do **not** proceed past Step 1 until the
  user types **"Agree"**. If they type **"Abort"** at any point, stop, delete any
  sensitive messages, and return.
- **Never store secrets in the repo.** Client secret, tokens, and the auth callback
  URL are sensitive. Store them per "Storing the credentials" below (`chmod 600`),
  never committed.
- **The user works in ONE incognito/private browser** for the whole flow — every
  console link is opened in that same window so they stay signed into the new
  account only.

### Relaying URLs over Telegram

Every URL must be **tap-to-copy, not clickable**: the user copies it and pastes it into
their separate **incognito** browser. A tap opens Telegram's in-app browser, which hides
your instructions, may be signed into the wrong account, and breaks the incognito
isolation / localhost callback. Tell them the first time: *"Copy this link and paste it
into the incognito browser — don't tap it."*

**How:** send the URL on its own, wrapped in single backticks, with `format: "markdownv2"`
— that makes it tap-to-copy and a URL inside backticks needs no escaping. Keep your prose
in separate replies. Full rule + self-check: `connectorskill.md` → "RELAYING LINKS OVER
CHAT". Everywhere below, the URL shown in a `code block` already includes the backticks —
that block **is** the literal `text` payload; send it with `format: "markdownv2"`, never
as a plain auto-linked URL.

---

## What gets connected

**APIs enabled** (Step 3, all in one click):

```
gmail.googleapis.com,drive.googleapis.com,calendar-json.googleapis.com,sheets.googleapis.com,docs.googleapis.com,slides.googleapis.com,tasks.googleapis.com,forms.googleapis.com,people.googleapis.com,script.googleapis.com
```

**OAuth scopes requested** (Step 5):

```
https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/calendar https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/documents https://www.googleapis.com/auth/spreadsheets https://www.googleapis.com/auth/presentations https://www.googleapis.com/auth/tasks https://www.googleapis.com/auth/contacts https://www.googleapis.com/auth/forms https://www.googleapis.com/auth/chat.spaces https://www.googleapis.com/auth/script.projects
```

Keep these two lists verbatim — together they are what makes the connected account
fully usable (every service enabled, every scope granted).

---

## Step 0 — Confirm and start

Before anything else, confirm the user wants to proceed. Send (adapt the product
name to your harness, or drop it):

> The Google connection process will take **10–15 minutes** and you'll need to
> create a brand-new Google account. I'll guide you one step at a time. If anything
> is unclear, just ask. Reply **"yes"** to begin, or **"no"** to cancel.

Wait for **"yes"**.

---

## Step 1/5 — Liability waiver (HARD GATE)

Send this **verbatim**:

> We will now connect a **Google Workspace** account (Email, Docs, Sheets, Slides)
> for use by your AI Agent.
>
> **WARNING:** Always create a **NEW, DEDICATED** account. **NEVER** connect an
> existing Google account.
>
> The AI Agent will have **full access** to this account. Because of this, you face
> severe risks, including **data loss**, **data leakage**, and **permanent account
> bans** by Google (for bot-like activity).
>
> **LIABILITY WAIVER:** By typing "Agree", you accept these risks. To the maximum
> extent permitted by law, you agree to release, hold harmless, and fully indemnify
> the developers against any claims, losses, or liabilities arising from data loss,
> data leaks, or account lockouts.
>
> Type **"Agree"** to proceed. Type **"Abort"** to stop.

- If the user types **"Agree"** (case-insensitive) → continue to Step 2.
- If they type **"Abort"** → stop and return.
- Any other reply → re-prompt / keep waiting. **Do not proceed without "Agree".**

---

## Step 2/5 — Create a NEW Google account

Send:

> **Step 2/5: Create a NEW Google Account**
>
> This process is quite complex and will take **10–15 minutes**. Please follow the
> instructions closely.
>
> To prevent accidentally linking your existing accounts, open a **NEW
> INCOGNITO/PRIVATE BROWSER** and paste this link:

Then the copy-paste block:

```
`https://accounts.google.com`
```

> Then **CREATE a NEW Google account** for use by your AI Agent.
>
> Type **"Done"** when you are done. Or type **"Abort"** to cancel.

Wait for **"Done"** (accept done/yes/ok/finished/complete). If anything else,
remind: *Please type "Done" when you're ready, or "Abort" to cancel.*

---

## Step 3/5 — Create project & enable APIs

Send:

> **Step 3/5: Create Project & Enable APIs**
>
> The next steps take you through creating and linking a Google Cloud Project to
> allow your AI Agent access to the new Google account.
>
> Use the same incognito browser from the previous step (you should still be signed
> in).
>
> Copy and paste this link:

Then the copy-paste block (this enables **all 10 APIs in one click**):

```
`https://console.cloud.google.com/flows/enableapi?apiid=gmail.googleapis.com,drive.googleapis.com,calendar-json.googleapis.com,sheets.googleapis.com,docs.googleapis.com,slides.googleapis.com,tasks.googleapis.com,forms.googleapis.com,people.googleapis.com,script.googleapis.com`
```

> 1. You will be prompted to select or create a project
> 2. Click **"Create Project"**
> 3. Give it any name (e.g. "Claude Agent")
> 4. Click **"Create"**. (A popup may appear, you need to click on the screen behind
>    the popup.)
> 5. **"Enable"** all the APIs
> 6. When everything is done, reply **"Done"** here
>
> Or type **"Abort"** to cancel.

Wait for **"Done"**. Then ask for the **Project ID**:

> Now I need the **Project ID**.
>
> You can find it in one of two ways:
> 1. Look at your browser's address bar — the Project ID appears after **project=**
> 2. Or go to this page and copy it from the blue dropdown at the top:

```
`https://console.cloud.google.com/welcome`
```

> The Project ID looks something like **my-project-123456** (lowercase, with
> hyphens).
>
> Paste the **Project ID** here:

**Validate** the reply: lowercase it, strip spaces, require it to match
`^[a-z][a-z0-9-]{5,29}$` (6–30 chars, starts with a lowercase letter, only
lowercase letters / digits / hyphens). If it doesn't match, send:

> That doesn't look like a valid Project ID. It should be 6–30 characters, starting
> with a lowercase letter, containing only lowercase letters, digits, and hyphens.
>
> Example: my-project-123456
>
> Please try again:

Once valid, confirm:

> Step 3 complete. Project ID: `<project_id>` — 10 Google APIs should now be enabled.

Hold onto `<project_id>` — the next three links embed it.

---

## Step 4/5 — OAuth consent screen, publish, and credentials

### Part A — OAuth consent screen

> **Step 4/5 (Part A): Set up the "OAuth" consent screen**
>
> This is what allows your AI Agent to authenticate itself to Google.
>
> Use the same incognito browser (you should still be signed in). Copy and paste
> this link:

```
`https://console.cloud.google.com/auth/overview/create?project=<project_id>`
```

> 1. Audience: Select **"External"**
> 2. App name: Claude Agent (or anything else you want, doesn't matter)
> 3. User support email: (select your email)
> 4. Developer contact email: (your email)
> 5. Click **"Save and Continue"** through all steps
>
> When done, come back here and reply **"Done"**. Or type **"Abort"** to cancel.

Wait for **"Done"**.

### Part B — Publish the app

> **Step 4/5 (Part B): "Publish" the app**
>
> This prevents access from expiring after 7 days. (Note: this does not allow other
> users to access your account.)
>
> Use the same incognito browser. Copy and paste this link:

```
`https://console.cloud.google.com/auth/audience?project=<project_id>`
```

> 1. You should see "Publishing status: Testing"
> 2. Click **"Publish app"**
> 3. Confirm when prompted
> 4. Status should change to **"In production"**
>
> Do not worry, "publishing" does not allow anyone else to access your account. It
> simply prevents access by the AI Agent to the Google workspace from expiring after
> 7 days.
>
> When done, come back here and reply **"Done"**. Or type **"Abort"** to cancel.

Wait for **"Done"**.

### Part C — Create the Desktop client credentials

> **Step 4/5 (Part C): Create credentials for access**
>
> Use the same incognito browser. Copy and paste this link:

```
`https://console.cloud.google.com/auth/clients?project=<project_id>`
```

> 1. Click the three dots button, then click **"Create client"**
> 2. Select **"Desktop app"** from the Application type dropdown
> 3. Name: Desktop Client 1 (or anything else, it doesn't matter)
> 4. Click **"Create"**
> 5. A popup will show your **Client ID** and **Client Secret**. Copy both values.
>
> Come back here and paste both **Client ID** and **Client Secret**, either in one
> message or separate messages. Or type **"Abort"** to cancel.
>
> **IMPORTANT:** The Client Secret is only shown **ONCE**! If you accidentally close
> the popup before copying, just go to the link above again and choose "Create
> client" again.

**Parsing the reply.** The user may paste raw JSON, `key: value` lines, or just two
bare strings. Extract:

- **Client ID** — ends with `.apps.googleusercontent.com`.
- **Client Secret** — starts with `GOCSPX-`.

Tolerate JSON (`{"installed": {...}}` or `{"web": {...}}`), `client_id:`/`client_secret:`
patterns, and strip invisible Unicode (zero-width spaces, BOM, directional marks)
that mobile copy/paste can insert. If only one value arrived, ask for the other:

- Got ID, missing secret → *"Got the Client ID! Now please copy and paste the Client Secret."*
- Got secret, missing ID → *"Got the Client Secret! Now please copy and paste the Client ID."*
- Got neither → *"Could not detect a Client ID or Client Secret in that message. Please try again."*

When you have **both**, confirm: *"Step 4 complete — credentials received."*

**Immediately secure the secret:** treat the user's message(s) containing the
Client ID / Client Secret as sensitive — plan to delete them at the end (see
"Cleaning up sensitive messages"), and **do not echo the secret back**.

---

## Step 5/5 — Workspace authorization (use `connectlocalhost.mjs`)

This is where you use the connect-localhost script to **generate the authorization
URL** and, after the user pastes the localhost callback back, to **exchange the code
for tokens**. The script keeps no state between the two calls — **you** hold the
`session` blob.

### 5a — Generate the auth URL

Run `start` with the workspace scopes and Google's offline/consent flags. (`start`
needs only the **public** client-id — the client secret is not used until the token
exchange in 5c, so don't put it on this command.)

```bash
node connectlocalhost.mjs start \
  --authorize-endpoint https://accounts.google.com/o/oauth2/v2/auth \
  --token-endpoint https://oauth2.googleapis.com/token \
  --client-id '<client_id>' \
  --port 8080 \
  --scope "https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/calendar https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/documents https://www.googleapis.com/auth/spreadsheets https://www.googleapis.com/auth/presentations https://www.googleapis.com/auth/tasks https://www.googleapis.com/auth/contacts https://www.googleapis.com/auth/forms https://www.googleapis.com/auth/chat.spaces https://www.googleapis.com/auth/script.projects" \
  --extra access_type=offline \
  --extra prompt=consent
```

Why each flag:

- `--authorize-endpoint` / `--token-endpoint` — Google's fixed OAuth endpoints.
- `--port 8080` — the redirect becomes `http://localhost:8080/callback`. A Google
  **Desktop** ("installed") client accepts any loopback port, so 8080 is fine.
- `--extra access_type=offline` — **required** so Google returns a **refresh
  token** (otherwise you only get a short-lived access token).
- `--extra prompt=consent` — forces the consent screen so the refresh token is
  issued reliably on re-auth.

`start` prints two JSON lines:

- `{"event":"auth_url","url":"https://accounts.google.com/o/oauth2/v2/auth?...","redirect_uri":"http://localhost:8080/callback"}`
  → **relay `url` to the user** (as a copy-paste block — see below).
- `{"event":"session", ...}` → **you keep this whole object**; pass it verbatim to
  `finish` in 5c. Do not show it to the user.

### 5b — Relay the auth URL and collect the callback

Send (put the actual `url` from the `auth_url` event inside the code block):

> **Step 5/5: Workspace Authorization**
>
> Final step! Grant workspace permissions (Gmail, Drive, Calendar, etc.).
>
> You will see warnings that the app is **unverified**. That is ok — that is the app
> that you just created.
>
> Use the same incognito browser. Copy and paste this link:

```
`<auth_url value from the start event — the real https://… URL>`
```

> **Select all** to grant access to all services such as Gmail, Calendar, etc.
>
> After clicking **Allow**, your browser will show a **"This site can't be reached"**
> error — that's expected!
>
> Copy the **FULL URL** from your browser's address bar. It should look something
> like:

```
http://localhost:8080/callback?state=...&code=...
```

> Paste it here. Or type **"Abort"** to cancel.

**Validate the reply:** it must contain `localhost`. If it doesn't but looks like a
URL or long string, nudge:

> That doesn't look like the right URL. It should start with `http://localhost`.
> Please copy the **full URL** from your browser's address bar after clicking Allow.
> The page will show a **"This site can't be reached"** error — that's normal. Copy
> the URL from the address bar at that point.

Treat the pasted callback URL as **sensitive** (it carries the auth code) — mark the
user's message for deletion at the end.

### 5c — Exchange the code for tokens

Feed the pasted URL plus the saved `session` to `finish`. Desktop clients are
confidential, so the client secret **is** needed here for the token exchange — pass
it via an **environment variable** (never on the command line, where it would show
in `/proc/<pid>/cmdline`):

```bash
GOOGLE_CLIENT_SECRET='<client_secret>' \
node connectlocalhost.mjs finish \
  --pasted "<full localhost callback URL the user pasted>" \
  --session '<the session JSON from 5a>' \
  --client-secret-env GOOGLE_CLIENT_SECRET
```

The script validates `state` (CSRF guard) before exchanging. It prints:

- `{"event":"credentials","access_token":"...","refresh_token":"...","expires_in":...,"token_type":"Bearer","token_endpoint":"https://oauth2.googleapis.com/token","client_id":"...","scopes":[...],...}`

If instead you get `{"event":"error",...}`:

- `STATE_MISMATCH` → the pasted URL is from a different attempt; re-send the auth URL.
- `OAUTH_ERROR` (e.g. `access_denied`) → the user declined a scope; ask them to redo
  Step 5b and **Select all**.
- `EXCHANGE_FAILED` → usually a wrong/expired code or a bad client secret; restart
  Step 5.

> **Refresh token required.** If `refresh_token` is `null`, the offline/consent
> flags didn't take. Re-run 5a–5c — Google only returns a refresh token with both
> `access_type=offline` **and** `prompt=consent` and a fresh consent.

### 5d — Get the account email

The connected account's own email isn't in the token response — fetch it with the
access token (keeps the Bearer token out of the process arg list):

```bash
printf 'header = "Authorization: Bearer %s"\n' "<access_token>" \
  | curl -s -K - https://www.googleapis.com/oauth2/v2/userinfo
```

Read `.email` from the JSON. If it's empty, the token is bad — restart Step 5.
Confirm: *"Step 5 complete — workspace authorization done for `<email>`."* (You store
the credentials in the next section.)

---

## Storing the credentials

Store the result **per `storingsecrets.md`** — *you* (Claude) store it; the scripts
never write to disk. The `finish` event gives you exactly the fields a
bundle needs: `access_token`, `refresh_token`, `client_id`, `token_endpoint`,
`scopes` (plus the `client_secret` you collected in Step 4C and the `<email>` from
5d). **Nothing is committed; `.env` is `chmod 600`.**

An OAuth credential is several values, so keep them together by **sharing one
prefix** — the prefix *is* the index, with **no separate file to maintain**. The
secrets are `<SVC>_<PURPOSE>_ACCESS_TOKEN` / `_REFRESH_TOKEN` / `_CLIENT_SECRET`;
store the non-secret companions (`client_id`, `token_endpoint`, `scopes`, and here
the account `email`) as sibling vars under the **same prefix** so they travel
together by name. Name the bundle `<SERVICE>_<TYPE>_<MODE>_<RESOURCE>` style — this
is a full-read/write account-wide Workspace credential, and because it is the **agent's
own dedicated account** (not the user's), it takes the `SERVICE_` prefix that marks
agent-owned accounts (see `storingsecrets.md` §4 — this disambiguates it from the
*user's* own Google Workspace). So `SERVICE_GOOGLE_WORKSPACE_RW`:

```
# .env  (chmod 600, never committed)
SERVICE_GOOGLE_WORKSPACE_RW_ACCESS_TOKEN=ya29....                                  # secret
SERVICE_GOOGLE_WORKSPACE_RW_REFRESH_TOKEN=1//....                                  # secret
SERVICE_GOOGLE_WORKSPACE_RW_CLIENT_SECRET=GOCSPX-...                               # secret
SERVICE_GOOGLE_WORKSPACE_RW_CLIENT_ID=...apps.googleusercontent.com               # non-secret
SERVICE_GOOGLE_WORKSPACE_RW_TOKEN_ENDPOINT=https://oauth2.googleapis.com/token    # non-secret
SERVICE_GOOGLE_WORKSPACE_RW_SCOPES='https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/gmail.modify ...'   # non-secret (all Step-5 scopes) — quote it (see below)
SERVICE_GOOGLE_WORKSPACE_RW_EMAIL=<email>                                         # non-secret: the connected account
```

> **Quote `SERVICE_GOOGLE_WORKSPACE_RW_SCOPES`.** OAuth scopes are a **space-separated**
> list (RFC 6749 §3.3). When a `.env` is loaded by shell-`source`ing it, an
> unquoted `KEY=url1 url2 …` is parsed as "run command `url2` with `KEY=url1` in its
> env" — so the value is truncated at the first space and, depending on the loader,
> the line may error and abort loading the file. **Single-quote the whole value**
> (as shown) so the spaces are inert. This is the only Workspace field with spaces;
> the rest are single tokens, but when in doubt, quote (see `storingsecrets.md` §1).

The env-var **name carries everything needed to pick it** — `SERVICE_GOOGLE_WORKSPACE_RW_*`
already says "Google Workspace, read+write." To act on the account, read the access
token from `SERVICE_GOOGLE_WORKSPACE_RW_ACCESS_TOKEN`; to refresh, read the sibling vars
sharing the `SERVICE_GOOGLE_WORKSPACE_RW_` prefix and call `refresh.mjs` (see below). Each
secret is individually rotatable; never cram several into one var or store a JSON
blob of secrets.

---

## Connection tests

Tell the user: *"Credentials stored ✅ — now testing them with a few live calls."* This is
the **agent's own** account, so write tests are correct here (the one place writes are fine).
Test the core services — one write call each (header `Authorization: Bearer <access_token>`
and `Content-Type: application/json`; all expect HTTP 2xx):

| Test | Call |
|---|---|
| Send email (to self) | `POST https://gmail.googleapis.com/gmail/v1/users/me/messages/send` with a base64url `raw` RFC-822 message From/To `<email>` |
| Create Doc | `POST https://docs.googleapis.com/v1/documents` body `{"title":"Test"}` |
| Create Sheet | `POST https://sheets.googleapis.com/v4/spreadsheets` body `{"properties":{"title":"Test"}}` |
| Create Slide | `POST https://slides.googleapis.com/v1/presentations` body `{"title":"Test"}` |
| Create Calendar event | `POST https://www.googleapis.com/calendar/v3/calendars/primary/events` with `summary` + `start`/`end` dateTimes |

Report a tally, e.g.:

> Test Results
>
> Passed: 5/5
> ✅ Send + receive email (self)
> ✅ Create + read Google Doc
> ✅ Create + read Google Sheet
> ✅ Create + read Google Slide
> ✅ Create + read Calendar event
>
> You are all set!

If a test fails, surface the HTTP status so the cause is visible (a 403 usually
means that API wasn't enabled in Step 3 or the scope wasn't granted in Step 5).

---

## Cleaning up sensitive messages

Before finishing, **delete the sensitive messages** from the chat history:

- the user's message(s) containing the **Client ID / Client Secret** (Step 4C),
- the user's message containing the **localhost callback URL** (Step 5b, carries the
  auth code),
- the **auth-URL message** you sent (contains the `client_id`).

On Telegram, delete each by `message_id` (track them as they arrive). Then confirm:

> ✅ Setup complete! Sensitive messages have been automatically deleted from the chat.

---

## Finishing up

Send a closing message (and reload/restart the harness if anything consumes the new
`.env` bundle at startup):

> `<email>` is connected. This will be the AI agent's working account.
>
> You can email this account or share documents to it via Google.
>
> The AI agent can now create Google docs, sheets or slide presentations and share
> them with you.

If you also have the user's **own** personal email (different from `<email>`), record
it (e.g. `USER_PERSONAL_EMAIL` in `.env`) so docs/calendar invites are shared with
them by default.

---

## Later: refreshing the access token

Access tokens expire (~1 hour). Refresh without re-signing-in using the stored
refresh token + client secret (both from env, never argv):

```bash
SERVICE_GOOGLE_WORKSPACE_RW_REFRESH_TOKEN='1//...' SERVICE_GOOGLE_WORKSPACE_RW_CLIENT_SECRET='GOCSPX-...' \
node refresh.mjs \
  --token-endpoint https://oauth2.googleapis.com/token \
  --client-id '<client_id>' \
  --refresh-token-env SERVICE_GOOGLE_WORKSPACE_RW_REFRESH_TOKEN \
  --client-secret-env SERVICE_GOOGLE_WORKSPACE_RW_CLIENT_SECRET
```

It emits a fresh `credentials` event — overwrite `SERVICE_GOOGLE_WORKSPACE_RW_ACCESS_TOKEN`
with the new `access_token`, and if the response carried a rotated `refresh_token`,
overwrite `SERVICE_GOOGLE_WORKSPACE_RW_REFRESH_TOKEN` too (otherwise keep the existing one).
The other sibling vars under the prefix are unchanged.

---

## Abort & error handling (any step)

- **"Abort"** at any prompt → stop immediately, delete sensitive messages, tell the
  user it's cancelled. Don't send further validation errors after an abort.
- **No reply for a long time** → it's fine to wait; a real script used a 5-minute
  per-prompt / 20-minute overall budget. Re-prompt gently rather than abandoning.
- **Wrong Project ID / client values / callback URL** → re-ask with the specific
  correction message above; never guess on the user's behalf.
