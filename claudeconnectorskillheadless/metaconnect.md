# Connecting Meta (Facebook, Instagram, Meta Ads, WhatsApp API, Threads)

A **Claude-driven** runbook for connecting a user's **Meta** accounts to a Claude
harness via a **long-lived System User access token**, so Claude can read (and, if
granted, manage) them over Meta's **Graph API** with direct HTTPS REST. One flow
covers any combination of these Meta services — the user picks which ones in Step 3,
and the use cases / permissions are tailored to that choice:

- **Facebook** — Page posts, comments, and organic Page insights
- **Instagram** — media, comments, and organic IG insights (via the linked Page)
- **Meta Ads** — ad accounts, campaigns, and paid-ad performance/insights (Marketing API)
- **WhatsApp API** — the **WhatsApp Business Platform / Cloud API** (send/receive
  messages, manage templates and phone numbers programmatically). **This is *not* the
  WhatsApp Business *app*** (the free consumer phone app for small businesses) — it is
  the developer API, tied to a **WhatsApp Business Account (WABA)** inside a Meta
  Business portfolio. If the user only has the phone app and no WABA, there is nothing
  to connect here.
- **Threads** — Threads profile content and insights (Threads API)

This is the headless, conversational replacement for a setup script: **Claude reads
this file and runs the flow itself**, talking the user through it one message at a
time. It corresponds to **connectorskill.md method #3 (simple API key / PAT)** — the
long-lived token sidesteps the OAuth-redirect problem (Meta's official OAuth MCP
breaks in Claude Code). The flow has two phases: **(1) create an "App"** (with use
cases for the chosen services), then **(2) create a "System User" and generate a
never-expiring access token**.

> Use this **only** when the user wants Claude to act on their **own** Meta business
> assets. It requires a **Business that is active on Meta, linked to the user's
> Facebook account, and already through Meta's Business Verification** (WhatsApp API
> and Ads in particular won't function on an unverified Business). If the Business is
> not verified, stop and tell the user to complete Business Verification first —
> nothing below will work without it. If it is not clear which Meta product is meant,
> **ask first** (Step 3 makes the user choose explicitly).

---

## Ground rules for Claude (read before starting)

- **Run interactively — never as a background / fire-and-forget job.** This flow
  needs the user's replies between steps (waiver, "Done" after each console action,
  the pasted access token). Drive it in a session that can receive those replies; a
  detached/background agent that only reports on completion will hang or fail.
- **Drive it yourself, one step at a time.** Assume the user is **non-technical**.
  Send **one step**, **wait for confirmation** before the next, keep each message
  short. Do not dump all the steps at once. The Meta console is genuinely fiddly —
  reproduce the wording and click-paths below faithfully.
- **The liability waiver is a hard gate.** Do **not** proceed past Step 1 until the
  user types **"Agree"**. If they type **"Abort"** at any point, stop, delete any
  sensitive messages, and return.
- **Shortest set of use cases wins.** When the app asks for "use cases" (Step 4),
  pick the **fewest** that cover the services the user chose in Step 3, and **never**
  pick a use case that touches *other people's* accounts — that forces Meta "App
  Verification" and stalls the whole flow. If Meta ever prompts for App Verification,
  you over-selected: go **back** and deselect.
- **Never store the token in the repo.** The System User access token is a
  long-lived, full-power credential. Store it per "Storing the credentials" below
  (`chmod 600`), never committed, and **never echo it back** to the user.

### Relaying URLs over Telegram

Every URL must be **tap-to-copy, not clickable**: the user copies it and pastes it
into their browser. A tap opens Telegram's in-app browser, which hides your
instructions and may be signed into the wrong account. Tell them the first time:
*"Copy this link and paste it into your browser — don't tap it."*

**How:** send the URL on its own, wrapped in single backticks, with
`format: "markdownv2"` — that makes it tap-to-copy and a URL inside backticks needs
no escaping. Keep your prose in separate replies. Full rule + self-check:
`connectorskill.md` → "RELAYING LINKS OVER CHAT". Everywhere below, the URL shown in
a `code block` already includes the backticks — that block **is** the literal `text`
payload; send it with `format: "markdownv2"`, never as a plain auto-linked URL.

---

## What gets connected

This is the **per-service map** that drives Step 4 (use cases) and Step 8
(permissions). The user picks services in **Step 3**; for each chosen service, add its
use case in Step 4 and request its permissions in Step 8. A use case is what unlocks
its permissions — **skip the use case and its permissions won't be offered at token
generation.** Use-case names are the **exact** ones from Meta's docs (full per-use-case
required/optional lists in the
[Appendix](#appendix--use-case--permission-mapping-internal-reference)); permissions
shown are the **read + insights** set.

| Service | Use case(s) to select | Read/insights permissions to add |
|---|---|---|
| **Facebook** (Pages) | **Manage everything on your Page** | `pages_show_list`, `pages_read_engagement`, `pages_read_user_content`, `read_insights` |
| **Instagram** | **Manage messaging & content on Instagram** + **Manage everything on your Page** (IG is reached via its linked Page, which supplies `instagram_basic`) | `instagram_manage_insights`, `instagram_manage_comments` + `instagram_basic` (media — from the Page use case) |
| **Meta Ads** | **Measure ad performance data with Marketing API** (read-focused) — or **Create & manage ads with Marketing API** if writes are wanted | `ads_read` (+ `ads_management` only for writes) |
| **WhatsApp API** | **Connect with customers through WhatsApp** | `whatsapp_business_management` (read WABA/phone numbers/templates) |
| **Threads** | **Access the Threads API** | `threads_basic` (+ `threads_manage_insights` for insights) |
| *(shared, almost always)* | — | `business_management` |

> **The Marketing API ≠ organic content.** Both Marketing-API use cases cover **ads
> only** — ad campaigns and *paid-ad* performance insights. They do **not** read
> Facebook/Instagram posts or **organic** engagement; that needs the Page / Instagram
> use cases. Selecting use cases for the user's **own** assets (assigned to the System
> User in Step 7) is first-party access and should **not** trigger App Verification; if
> Meta still prompts for verification, you over-selected something that touches *other
> people's* accounts — back out of that one.
>
> **Read-only ads, note:** both Marketing-API use cases list `ads_management` as a
> *required* permission of the use case, but at **token generation** (Step 8) you pick
> which permissions the token actually carries — select **`ads_read`** and leave
> `ads_management` unchecked for a read-only token.
>
> **WhatsApp API, note:** there is no separate read-only WhatsApp permission —
> `whatsapp_business_management` covers reading the WABA, its phone numbers, and
> message templates; `whatsapp_business_messaging` is what actually sends/receives
> messages, so add it **only** if the user wants Claude to message. WhatsApp also
> **requires a Business portfolio** on the app (Step 4) and a **WABA + phone number**
> assigned to the System User (Step 7).

The official mapping (source of the Appendix table — internal reference, do **not**
relay to the user) is:

```
https://developers.facebook.com/docs/development/create-an-app/use-cases-permission-mapping/
```

**Permissions to request at token generation** (Step 8) — assemble the baseline from
**only the services the user chose in Step 3**. Full read + insights across everything
would be:

```
pages_show_list  pages_read_engagement  pages_read_user_content  read_insights  instagram_basic  instagram_manage_insights  instagram_manage_comments  ads_read  whatsapp_business_management  threads_basic  threads_manage_insights  business_management
```

Drop every family the user didn't pick (e.g. omit all `instagram_*` if no Instagram,
all `whatsapp_*` if no WhatsApp API, `ads_read` if no ads). Only if the user wants
Claude to **manage** (not just read), add the matching write scopes
(`pages_manage_posts`, `instagram_content_publish`, `ads_management`,
`whatsapp_business_messaging`, `threads_content_publish`). Default to the read set — it
is reversible and lower-risk.

---

## Step 0 — Confirm, check prerequisites, and start

Before anything else, confirm the user wants to proceed and that the prerequisite is
met. Send (adapt the product name to your harness, or drop it):

> Connecting your Meta accounts (Facebook, Instagram, Meta Ads, WhatsApp API,
> Threads) takes **15–20 minutes** and the Meta console is genuinely fiddly — I'll
> guide you one step at a time, and you'll choose exactly which services to connect.
> First, a requirement: you need a **Business on Meta**, linked to your Facebook
> account, that has **already completed Meta's Business Verification**.
>
> Is your Business verified? Reply **"yes"** to begin, **"no"** if you still need to
> verify (I'll point you to it), or **"cancel"** to stop.

- **"yes"** → continue to Step 1.
- **"no"** → tell them to finish Business Verification in Meta Business Settings
  first, then come back; stop here.
- **"cancel"** → stop and return.

---

## Step 1/8 — Liability waiver (HARD GATE)

Send this **verbatim**:

> We will now connect your **Meta** accounts — **Facebook, Instagram, Meta Ads,
> WhatsApp API, and/or Threads** (you'll choose which) — for use by your AI Agent.
>
> The process is unfortunately **very complex**: first we create an **"App"**, then
> we create a **"System User"** and generate an **access token**. I'll do my best to
> guide you through every click.
>
> The AI Agent will have access to the Meta assets you assign it (Pages, Instagram,
> Ad accounts, WhatsApp accounts). Because of this, you face real risks, including
> **data loss**, **data leakage**, **unintended ad spend or messaging**, and
> **account restrictions** by Meta.
>
> **LIABILITY WAIVER:** By typing "Agree", you accept these risks. To the maximum
> extent permitted by law, you agree to release, hold harmless, and fully indemnify
> the developers against any claims, losses, or liabilities arising from data loss,
> data leaks, ad spend, or account restrictions.
>
> Type **"Agree"** to proceed. Type **"Abort"** to stop.

- If the user types **"Agree"** (case-insensitive) → continue to Step 2.
- If they type **"Abort"** → stop and return.
- Any other reply → re-prompt / keep waiting. **Do not proceed without "Agree".**

---

## Step 2/8 — Register as a Meta developer

Send:

> **Step 2/8: Register as a Meta developer**
>
> Copy and paste this link into your browser and complete the quick developer
> registration:

```
`https://developers.facebook.com/async/registration`
```

> If you've **already registered as a developer before**, just reply **"done"**.
> Otherwise finish the registration and then reply **"done"**. Or type **"Abort"** to
> cancel.

Wait for **"done"** (accept done/yes/ok/finished). Anything else → gently re-ask.

---

## Step 3/8 — Choose which Meta services to connect

This choice **drives everything after it** — the use cases you pick in Step 4, the
permissions in Step 8, the assets assigned in Step 7, and the read tests. Ask the user
explicitly; don't assume. Send:

> **Step 3/8: Which Meta services should I connect?**
>
> Pick any combination — reply with the ones you want:
>
> • **Facebook** — read your Page posts, comments, and insights
> • **Instagram** — read your IG media, comments, and insights
> • **Meta Ads** — read your ad campaigns and performance (add "manage" if you want me
>   to create/edit ads)
> • **WhatsApp API** — the **WhatsApp Business Platform / Cloud API** (manage templates
>   & phone numbers, send/receive messages). *This is the developer API, not the
>   free WhatsApp Business phone app — it needs a WhatsApp Business Account (WABA) in
>   your Meta Business.*
> • **Threads** — read your Threads profile content and insights
>
> Tell me which (e.g. "Facebook and Instagram", or "just Ads"), and whether you want
> **read-only** or also **manage/write** for each. Or type **"Abort"** to cancel.

**Record the selection** — you'll reuse it verbatim in Steps 4, 7, and 8, and to pick
which read tests to run. Map each chosen service to its use case(s)/permissions using
the per-service table in "What gets connected" above. If the user picked **WhatsApp
API**, confirm they actually have (or will create) a **WABA** — without one there is
nothing to connect. If the selection is empty or unclear, re-ask before proceeding.

---

## Step 4/8 — Create the App and pick use cases

Send:

> **Step 4/8: Create your App**
>
> Copy and paste this link to start creating an app:

```
`https://developers.facebook.com/apps/creation/`
```

> Meta will ask you to pick from a list of app **"use cases"**, grouped into
> categories (Ads & monetization, Content management, …). **Pick only the ones for the
> services you chose** — each use case unlocks a set of permissions, and extras you
> don't need can trigger Meta "App Verification" and stall everything. For the services
> you picked:
>
> • **Facebook** → **Manage everything on your Page** (Content management)
> • **Instagram** → **Manage messaging & content on Instagram** (Content management) —
>   plus keep **Manage everything on your Page**, since Instagram is reached through
>   its linked Facebook Page
> • **Meta Ads** → **Measure ad performance data with Marketing API** (read), or
>   **Create & manage ads with Marketing API** if you also want me to create/edit ads.
>   *Ads only — this does not read your posts or organic engagement.*
> • **WhatsApp API** → **Connect with customers through WhatsApp** (you'll be asked to
>   connect a **Business portfolio** — required for WhatsApp)
> • **Threads** → **Access the Threads API**
>
> If Meta ever prompts you for **"App Verification"**, you've selected too much — click
> **Previous** and deselect use cases until the prompt goes away. (Accessing your
> *own* assets is fine; verification is triggered by use cases that touch *other
> people's* accounts.)
>
> Finish creating the app, then reply **"done"** with the **App name** you chose. Or
> type **"Abort"** to cancel.

Send the user **only the bullets for the services they selected in Step 3** — don't
paste the whole list. Wait for **"done"** and capture the **app name** (you'll
reference it by name in Steps 6–8). The permissions you request in Step 8 must be
covered by the use cases picked here — if a permission isn't offered later, a use
case is missing; send the user back to add it. If they're unsure which use case
grants which permission, **work it out yourself** from the use-case → permission
mapping in the [Appendix](#appendix--use-case--permission-mapping-internal-reference)
and tell them which use case to tick — that mapping is an internal reference; do
**not** relay its link to the user.

---

## Step 5/8 — Add a privacy policy URL and Publish the app

The app must be **Live** before a System User token will work. Send:

> **Step 5/8: Publish the app (make it "Live")**
>
> 1. In your app, look at the **left-hand menu** and click **"Publish"**.
> 2. It will ask you to add a **Privacy Policy URL** in **App Settings**. Paste the
>    URL of your Business's general privacy policy there, and **Save changes**.
> 3. Go **back to the Publish page** and click **Publish**.
> 4. If all is well, the app status should now read **"Live"**.
>
> Reply **"done"** when the status shows **Live**. Or type **"Abort"** to cancel.

Wait for **"done"**. If the user reports the status is *not* Live, the usual cause is
a missing/invalid privacy policy URL — have them re-check App Settings, then retry.

---

## Step 6/8 — Create a System User

Send:

> **Step 6/8: Create a System User**
>
> Copy and paste this link (Meta Business Settings → System Users):

```
`https://business.facebook.com/settings/system-users`
```

> 1. Click the **"Add"** button.
> 2. Give the System User a **single-word name** (e.g. `claudeagent`).
> 3. Set the role to **"Administrator"**.
> 4. Create it.
>
> Reply **"done"** when the System User exists. Or type **"Abort"** to cancel.

Wait for **"done"**.

---

## Step 7/8 — Assign assets to the System User

This step is **not obvious** and is the most common place people get stuck — walk it
carefully. **Only walk through the asset types for the services chosen in Step 3.**
Send (include just the relevant numbered items):

> **Step 7/8: Give the System User access to your assets**
>
> Still on the System Users page, with your new System User selected:
>
> 1. Click the **"⋯"** (three dots) button, then choose **"Assign assets"**.
> 2. **Apps** (always): in the left pane pick **"Apps"**, select **your app** (named
>    *<app name>*), then in the right pane turn on **Full access → Manage App**.
> 3. **Facebook / Instagram** → **Pages:** in the left pane pick **"Facebook Pages"**,
>    select your Page (an Instagram business account is reached through its linked
>    Page), then choose the access — **Insights only** (read) or also content
>    management.
> 4. **Meta Ads** → **Ad accounts:** in the left pane pick **"Ad accounts"**, select
>    your ad account(s), then choose **View only** (read) or also Manage.
> 5. **WhatsApp API** → **WhatsApp accounts:** in the left pane pick **"WhatsApp
>    accounts"**, select your **WhatsApp Business Account (WABA)**, then choose the
>    access level. *While here, copy the **WABA ID** (shown next to the account name)
>    and your **Business ID** (in the Business Settings URL as `business_id=…`, or on
>    the Business Info page) — paste both back to me; I'll need them for the config
>    and tests.*
> 6. Save the assignments.
>
> Reply **"done"** when all the assets you want are assigned. Or type **"Abort"** to
> cancel.

Wait for **"done"**. If they connected WhatsApp, capture the **WABA ID** and
**Business ID** they paste into `META_TOKEN_RO_ALL_WABA_ID` / `_BUSINESS_ID` (the
WhatsApp tests in the next section need the WABA ID). Remind the user that whatever
they **don't** assign here, Claude **cannot** see — so assign every Page / Instagram
/ Ad account / WABA they want Claude
to work with. (Threads access rides on the Instagram/Threads profile linked to the
app, so there's no separate Threads asset to assign here.)

---

## Step 8/8 — Generate the access token

Send (list **only** the permission lines for the services chosen in Step 3):

> **Step 8/8: Generate the access token**
>
> Still on your System User:
>
> 1. Click **"Generate Token"**.
> 2. When asked **which App**, choose **<app name>** (the app you created).
> 3. For **Token expiration**, choose **"Never"**.
> 4. It will ask which **permissions** to grant — select the read + insights baseline
>    for the services you chose:
>
>    • Facebook: `pages_show_list`, `pages_read_engagement`,
>      `pages_read_user_content`, `read_insights`
>    • Instagram: `instagram_basic`, `instagram_manage_insights`,
>      `instagram_manage_comments`
>    • Meta Ads: `ads_read`
>    • WhatsApp API: `whatsapp_business_management` (+ `whatsapp_business_messaging`
>      only to send/receive messages)
>    • Threads: `threads_basic`, `threads_manage_insights`
>    • Shared: `business_management`
>
>    (Add write permissions like `ads_management`, `pages_manage_posts`,
>    `instagram_content_publish`, or `whatsapp_business_messaging` **only** if you want
>    me to *change*/send things, not just read.)
> 5. Meta will now show the **token**. **Copy it and paste it back here.**
>
> ⚠️ The token is shown **only once**. If you miss it, just click **Generate Token**
> again to make a new one. Or type **"Abort"** to cancel.

**When the user pastes the token:**

- Treat the message as **sensitive** — mark it for deletion at the end and **do not
  echo it back**.
- Meta System User tokens are long opaque strings (often prefixed `EAA…`). Strip
  whitespace and invisible Unicode (zero-width spaces, BOM) that mobile copy/paste can
  insert. If the reply clearly isn't a token, ask them to copy it again.
- **Store it first, then validate it live** — store per "Storing the credentials"
  below, then run the read-only "Connection tests" to confirm the token works and to
  capture the IDs you save alongside it. If a test fails, fix the cause (a missing
  scope or unassigned asset) and overwrite the stored value; don't declare success
  until the tests pass.

---

## Storing the credentials

Store the token **per `storingsecrets.md`** — *you* (Claude) store it; nothing is
committed and `.env` is `chmod 600`.

A Meta System User token is a **single, long-lived (never-expiring) credential** — it
is **not** an OAuth bundle, so there is **no refresh token and no client secret to
keep**. One secret var suffices, named `<SERVICE>_<TYPE>_<MODE>_<RESOURCE>`: this is a
Meta token, read-only baseline, account-wide → `META_TOKEN_RO_ALL` (use
`META_TOKEN_RW_ALL` if the user granted management permissions).

Store the **non-secret IDs you'll need for every Graph API call** as sibling vars
under the **same prefix**, so they travel together by name (you discover these during
the read test below):

Store **only the IDs for the services the user actually connected** — skip the
sibling vars for services they didn't pick.

```
# .env  (chmod 600, never committed)
META_TOKEN_RO_ALL=EAA...                       # secret — System User access token, never expires
META_TOKEN_RO_ALL_APP_ID=<app id>             # non-secret
META_TOKEN_RO_ALL_BUSINESS_ID=<business id>   # non-secret
META_TOKEN_RO_ALL_PAGE_ID=<page id>           # non-secret (Facebook Page)
META_TOKEN_RO_ALL_IG_ID=<ig business id>      # non-secret (Instagram business account)
META_TOKEN_RO_ALL_AD_ACCOUNT_ID=act_<id>      # non-secret (Meta Ads account, keep the act_ prefix)
META_TOKEN_RO_ALL_WABA_ID=<waba id>           # non-secret (WhatsApp Business Account)
META_TOKEN_RO_ALL_WA_PHONE_ID=<phone number id>  # non-secret (WhatsApp phone number id)
META_TOKEN_RO_ALL_THREADS_ID=<threads user id>   # non-secret (Threads profile)
META_TOKEN_RO_ALL_SCOPES='pages_show_list pages_read_engagement pages_read_user_content read_insights instagram_basic instagram_manage_insights instagram_manage_comments ads_read whatsapp_business_management threads_basic threads_manage_insights business_management'   # non-secret — only the scopes you granted; space-separated, single-quote it
```

> **Quote `…_SCOPES`.** It is a **space-separated** list; when a `.env` is loaded by
> shell-`source`ing it, an unquoted `KEY=a b c` is parsed as "run command `b` with
> `KEY=a` in its env" — truncating the value and possibly aborting the load.
> **Single-quote the whole value** (see `storingsecrets.md` §1). The token and the IDs
> are single tokens and need no quoting.

The env-var **name carries everything needed to pick it** — `META_TOKEN_RO_ALL`
already says "Meta token, read-only, account-wide." To act, read the token from
`META_TOKEN_RO_ALL` and the IDs from its siblings. Re-source `.env` at call time so a
freshly-stored token is picked up without restarting the harness:

```bash
set -a; source "$CLAUDE_HOME/.env"; set +a
```

---

## Connection tests (recommended) — strictly READ-ONLY

Confirm the token actually works **before** declaring success, using Meta's **Graph
API** with plain REST `GET`s (no writes). Tell the user *"Credentials stored ✅ — now
testing them by reading from the service (read-only)…"*. Use a current Graph API version (e.g. `v23.0`). **Pass the token in an
`Authorization: Bearer` header, never in the URL query string or on the command
line** — a `?access_token=…` query param lands in argv (`/proc/<pid>/cmdline`),
shell history, and server access logs. Feed the header to `curl` from **stdin** via
`-K -` (see the example below). **Run only the rows for the services the user
connected** (the token-identity row always). Each call should return HTTP `200` with
JSON (no `error` object).

| Service | Test | Call (read-only `GET`, token via `Authorization: Bearer` header) | Captures |
|---|---|---|---|
| (always) | Token identity | `https://graph.facebook.com/v23.0/me?fields=id,name` | — |
| Facebook | List Pages | `https://graph.facebook.com/v23.0/me/accounts?fields=id,name` | `PAGE_ID` |
| Facebook | Page insights | `https://graph.facebook.com/v23.0/<page id>/insights/page_impressions` | — |
| Instagram | Resolve IG account | `https://graph.facebook.com/v23.0/<page id>?fields=instagram_business_account` | `IG_ID` |
| Instagram | Read IG profile | `https://graph.facebook.com/v23.0/<ig id>?fields=username,media_count` | — |
| Meta Ads | List ad accounts | `https://graph.facebook.com/v23.0/me/adaccounts?fields=id,name` | `AD_ACCOUNT_ID` |
| Meta Ads | Read campaigns | `https://graph.facebook.com/v23.0/<ad_account_id>/campaigns?fields=name,status` | — |
| WhatsApp API | List WABA phone numbers | `https://graph.facebook.com/v23.0/<waba id>/phone_numbers` | `WA_PHONE_ID` |
| WhatsApp API | Read message templates | `https://graph.facebook.com/v23.0/<waba id>/message_templates?fields=name,status` | — |
| Threads | Read Threads profile | `https://graph.threads.net/v1.0/me?fields=id,username` | `THREADS_ID` |

(Threads uses its **own** host `graph.threads.net`, not `graph.facebook.com`.) Send
the token in the `Authorization` header, fed to `curl` from stdin so it never lands
in argv / shell history:

```bash
TOK='<the token the user sent>'
printf 'header = "Authorization: Bearer %s"\n' "$TOK" \
  | curl -s -K - -o /tmp/meta_test.json -w '%{http_code}\n' \
    "https://graph.facebook.com/v23.0/me?fields=id,name"
```

Read the IDs surfaced by the per-service calls into the sibling `.env` vars above.
Then report a tally over **only the tests you ran**, e.g.:

> Test Results
>
> Passed: 5/5 (read-only) — Facebook + Instagram
> ✅ Token identity
> ✅ List Facebook Pages
> ✅ Read Page insights
> ✅ Resolve Instagram account
> ✅ Read Instagram profile
>
> You are all set!

If a call returns an `error`, surface Meta's `error.message` / `error.code` so the
cause is visible. Common ones: a **missing permission** (the scope wasn't selected in
Step 8) or an **unassigned asset** (the Page/Ad account/WABA wasn't assigned in Step
7) — both are fixable by redoing that step. (Clean up `/tmp/meta_test.json` afterward.)

---

## Cleaning up sensitive messages

Before finishing, **delete the sensitive message** from the chat history:

- the user's message containing the **access token** (Step 8).

On Telegram, delete it by `message_id` (track it as it arrives). Then confirm:

> ✅ Setup complete! The message containing your token has been deleted from the chat.

---

## Finishing up

Send a closing message (re-source `.env` if the harness reads it at startup):

> Your Meta accounts are connected. The AI agent can now read
> <list only the services the user connected, e.g. "your **Facebook Page** posts &
> insights, **Instagram** insights, and **Meta Ads** campaigns">
> <add "and manage them" only if write scopes were granted>.
>
> The token never expires, so this is a one-time setup.

---

## Later: token longevity & rotation

The System User token was generated with expiration **"Never"**, so there is **no
refresh step** — unlike OAuth flows, it does not need `refresh.mjs`. It can still be
**revoked** by Meta if the System User is removed, the app is taken offline, an asset
is unassigned, or a permission is changed. If Graph API calls start returning an
`OAuthException`, the token is dead — re-run **Step 8** to generate a fresh one (the
app and System User from Steps 4–7 stay in place), validate it, and overwrite
`META_TOKEN_RO_ALL` in `.env`. Treat the token like any other secret and rotate it
this same way if it leaks.

---

## Abort & error handling (any step)

- **"Abort"** at any prompt → stop immediately, delete the token message if one
  arrived, tell the user it's cancelled. Don't send further validation errors after an
  abort.
- **Business not verified** → cannot proceed; point the user to Meta Business
  Verification and stop (Step 0).
- **Meta demands "App Verification"** → over-broad use cases were picked in Step 4;
  have the user go back and deselect until the prompt disappears.
- **App status not "Live"** → almost always a missing/invalid privacy policy URL
  (Step 5); re-check App Settings.
- **No reply for a long time** → it's fine to wait; re-prompt gently rather than
  abandoning.

---

## Appendix — Use-case → permission mapping (internal reference)

Replicated from Meta's **"Create an App with Meta"** docs (*Use Case Permission
Mapping*, updated Sep 16 2025) so Claude can pick the right use cases/permissions
**without** fetching the page (Meta blocks automated fetches). This is the source of
truth for the recommendations above — when guiding the user, match on these
**permissions**, since the use-case *labels* in the UI shift slightly between Graph
API versions.

How to read it: adding a use case to the app auto-adds its **required**
permissions/features (can't be removed); you then opt into the **optional** ones you
need. At **token generation** (Step 8) you choose which of these the System User token
actually carries. Items that aren't `lower_snake_case` (e.g. *Marketing API Access
Tier*, *Business Asset User Profile Access*) are **features**, not permissions.

> The required/optional split is transcribed from the docs' two-column table; where a
> column break was ambiguous in the source, the grouping is best-effort — treat the
> union of both columns as "available for this use case." The **bolded** rows are the
> ones this runbook recommends for reading + insights.

| Use case | Required permissions/features | Optional permissions/features |
|---|---|---|
| **Manage everything on your Page** | `business_management`, `pages_show_list`, `public_profile` | `email`, `pages_read_engagement`, `pages_read_user_content`, `pages_manage_engagement`, `pages_manage_posts`, `pages_manage_metadata`, `read_insights`, `ads_management`, `ads_read`, `catalog_management`, `instagram_basic`, `instagram_business_basic`, `facebook_branded_content_ads_brand`, `facebook_creator_marketplace_discovery`, `instagram_branded_content_ads_brand`, `instagram_branded_content_brand`, `instagram_branded_content_creator`, `instagram_creator_marketplace_discovery`, `instagram_creator_marketplace_messaging`, *Live Video API*, *Human Agent*, *Business Asset User Profile Access* |
| **Manage messaging & content on Instagram** | `public_profile` | `instagram_basic` (legacy), `instagram_content_publish`, `instagram_manage_comments`, `instagram_manage_contents`, `instagram_manage_engagement`, `instagram_manage_insights`, `instagram_manage_messages`, `instagram_manage_upcoming_events`, `instagram_business_content_publish`, `instagram_business_manage_comments`, `instagram_business_manage_insights`, `instagram_business_manage_messages`, `instagram_shopping_tag_products`, `pages_read_engagement`, `pages_show_list`, *Instagram Public Content Access*, *Business Asset User Profile Access* |
| **Measure ad performance data with Marketing API** | `public_profile`, `ads_read`, `ads_management`, `business_management`, *Marketing API Access Tier* | `pages_read_engagement`, `pages_show_list`, `email`, *Business Asset User Profile Access* |
| **Create & manage ads with Marketing API** | `public_profile`, `ads_management`, `ads_read`, `business_management`, *Marketing API Access Tier* | `pages_read_engagement`, `pages_show_list`, `pages_manage_ads`, `catalog_management`, `threads_business_basic`, `email`, *Business Asset User Profile Access* |
| **Capture & manage ad leads with Marketing API** | `public_profile`, `ads_management`, `ads_read`, `business_management`, `leads_retrieval`, `pages_manage_ads`, `pages_read_engagement`, `pages_show_list`, *Marketing API Access Tier* | `email`, `pages_manage_metadata`, *Business Asset User Profile Access* |
| **Access the Threads API** | `threads_basic` | `threads_read_replies`, `threads_manage_replies`, `threads_content_publish`, `threads_manage_insights`, `threads_keyword_search`, `threads_profile_discovery`, `threads_manage_mentions`, `threads_delete`, `threads_location_tagging`, `threads_share_to_instagram` |
| **Engage with customers on Messenger from Meta** | `public_profile`, `business_management`, `pages_manage_metadata`, `pages_messaging`, `pages_show_list` | `email`, `ads_management`, `instagram_basic`, `instagram_manage_messages`, `pages_read_engagement`, `pages_user_gender`, `pages_user_locale`, `pages_user_timezone`, `pages_utility_messaging`, `paid_marketing_messages`, `marketing_messages_messenger`, *Business Asset User Profile Access* |
| **Connect with customers through WhatsApp** | `whatsapp_business_messaging`, `whatsapp_business_management`, `public_profile`, `business_management` | `whatsapp_business_manage_events`, `email`, *manage_app_solution* |
| **Manage products with Catalog API** | `public_profile`, `catalog_management` | `email` |
| **Share or create fundraisers on Facebook and Instagram** | `public_profile`, `manage_fundraisers` | `email` |
| **Authenticate and request data from users with Facebook Login** | `public_profile` | `user_age_range`, `user_gender`, `user_link`, `user_friends`, `user_location`, `user_likes`, `user_photos`, `user_videos`, `user_posts` |
| **Advertise on your app with Meta Audience Network** | `public_profile` | `email`, `user_hometown`, `user_birthday` |
| **Launch an Instant Game on Facebook and Messenger** | `gaming_profile` | `gaming_user_picture`, `gaming_user_locale`, `email`, *Instant Games Zero Permission Access* |
| **Embed Facebook, Instagram and Threads content in other websites** | *Meta oEmbed Read*, *Threads oEmbed Read* | — |
| **Join ThreatExchange** | *ThreatExchange* | — |

Two use cases in the picker — **Create & manage app ads with Meta Ads Manager**
("Does not include access to Marketing API") and **Allow users to transfer their data
to other apps** — are **not** listed in the source mapping table, so their permission
sets aren't reproduced here.

**Key takeaways for read + insights (what this runbook recommends):**

- **Facebook organic** posts/comments + insights → *Manage everything on your Page* +
  optional `pages_read_engagement`, `pages_read_user_content`, `read_insights`.
- **Instagram organic** media/comments + insights → *Manage messaging & content on
  Instagram* + optional `instagram_manage_insights`, `instagram_manage_comments`;
  `instagram_basic` (basic media/profile) comes from the *Manage everything on your
  Page* use case, and IG is reached through its linked Page either way.
- **Ads** read/insights → *Measure ad performance data with Marketing API* (read-
  focused) or *Create & manage ads with Marketing API*; grant `ads_read` at the token
  step and omit `ads_management` for read-only.
- **WhatsApp API** (WhatsApp Business Platform / Cloud API — *not* the consumer app) →
  *Connect with customers through WhatsApp*; `whatsapp_business_management` reads the
  WABA / phone numbers / templates, `whatsapp_business_messaging` sends & receives.
  Requires a Business portfolio on the app and a WABA assigned to the System User.
- **Threads** → *Access the Threads API*; `threads_basic` (read profile/threads) +
  `threads_manage_insights` (insights). Threads calls use the `graph.threads.net` host.
