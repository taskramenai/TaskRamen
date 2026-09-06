# Connecting SimplyBook.me (appointment / booking system)

A **Claude-driven** runbook for connecting **SimplyBook.me** — a booking platform common in
clinics, salons, and other appointment-based businesses. There is **no official claude.ai
connector and no official MCP server**; SimplyBook is reached through its **JSON-RPC API**
with a dashboard-generated **API key**. This is a **simple API key** service
(**connectorskill.md method #3**), but with a critical twist: it has **two unrelated auth
tiers**, and picking the wrong one silently caps you at read-only.

> **Verify live — this drifts.** SimplyBook's dashboard section names, endpoint hosts, and
> method names change. Confirm against the SimplyBook dashboard and
> `simplybook.me/en/api` as you go; the values below were verified live against a real
> account but are a starting point, not ground truth.

---

## Ground rules for Claude (read before starting)

- **Run interactively — never as a background / fire-and-forget job.** The user has to open
  their dashboard and paste values back. Drive it in a session that can receive replies; a
  detached/background agent that only reports on completion will hang.
- **Drive it yourself, one step at a time.** Assume the user is **non-technical**. Send
  **one step**, **wait for the reply** before the next, keep each message short.
- **Never store the key in the repo.** Store in `.env` (`chmod 600`), never committed.
- **Relay every URL as a tap-to-copy code span, not a clickable link.** Send it on its own,
  wrapped in single backticks, with `format: "markdownv2"`. Details: `connectorskill.md` →
  "RELAYING LINKS OVER CHAT".

---

## The two auth tiers — pick the right one FIRST

Decide what the user actually needs before sending any steps, because the two tiers use
different keys and unlock different things:

1. **Client / widget tier — `getToken(company_login, api_key)`.** The `api_key` comes from
   the dashboard's **Custom Features → API** (a.k.a. "Account Info → API") section. This
   token is **read-mostly**: it's scoped for the public booking widget (list services, read
   available slots, submit a booking as a visitor). **It cannot create/edit services, staff,
   or working hours.** Use it only for embedding/reading — never assume it unlocks admin
   methods.
2. **Admin tier — `getUserToken(company_login, user_login, api_user_key)`.** This is the
   real admin path and the one that unlocks `addServiceProvider` / `editServiceProvider` /
   `setWorkDayInfo` and the other ~80 admin methods (services, staff/providers, working
   hours, bookings management). Needed for any automation that **provisions or edits** the
   booking setup rather than just reading it.

**Default to the admin tier** for anything that manages the account; only use the widget tier
if the goal is purely read/embed. The steps below cover the **admin tier** (the widget key is
just the "Custom Features → API" value if you need it too).

## Step 1 — User gets the admin API User Key

Relay the SimplyBook login as a tap-to-copy send:

```
`https://simplybook.me/en/login`
```

Then tell the user (verified live against a real account):

- In the dashboard, go to **Account Info → "For developers" section → User API Keys** and
  **generate a key** there.
- **No separate dashboard user needs to be created** — the generated key is automatically
  tied to whichever account is currently logged in. The `user_login` is that same account's
  own login/email, shown right on the Account Info page. (An earlier assumption that a
  dedicated user had to be created first was wrong — don't do that.)
- API User Keys from this form **bypass IP verification**, unlike calling `getUserToken`
  with a plain dashboard password.

Ask the user to paste back three things:
1. their **company login** (the `company_login` / subdomain, e.g. the `xxxx` in
   `xxxx.simplybook.me`),
2. their **user login** (email shown on Account Info),
3. the **API User Key** they just generated.

Wait for all three.

## Step 2 — Validate the key live (do not skip)

Mint an admin token with the pasted values. Capture the key with a quoted heredoc so the
shell does no expansion (treat it as untrusted input):

```bash
IFS= read -r SB_API_USER_KEY <<'EOF'
<the API User Key the user sent>
EOF
curl -s -o /tmp/sb_login.json -w '%{http_code}' \
  -X POST https://user-api.simplybook.me/login \
  -H "Content-Type: application/json" \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"jsonrpc":"2.0","method":"getUserToken","params":["<company_login>","<user_login>",sys.argv[1]],"id":1}))' "$SB_API_USER_KEY")"
```

- **`200` with a `result` token** → valid admin credential. (Optionally confirm it's really
  admin-scoped by calling one admin read method — see Step 4 — e.g. `getUnitList`.)
- **`200` with an `error`** (e.g. wrong key / login) → read the `error.message`, tell the
  user plainly, and ask them to re-check and resend (back to Step 1). Do **not** store an
  unvalidated key.
- **Non-200 / no response** → couldn't reach SimplyBook; ask the user to retry.

(Clean up `/tmp/sb_login.json` afterward. Building the JSON body with `python3 -c` avoids
fragile hand-escaping of the key in the shell.)

## Step 3 — Store the credentials

The **API User Key** is builder/admin access — store it **local-only**, never as a
site-runtime key. Store in `.env` (`chmod 600`, never committed), named per
`storingsecrets.md` (`<OWNER>_<SERVICE>_<TYPE>_<MODE>_<RESOURCE>`; `<OWNER>` = `USER`):

```
USER_SIMPLYBOOK_APIKEY_RW_ADMIN=<api_user_key>   # admin tier — provision/edit services, staff, hours
USER_SIMPLYBOOK_COMPANY_LOGIN=<company_login>     # company subdomain (needed on every call)
USER_SIMPLYBOOK_USER_LOGIN=<user_login>           # account email (needed to mint the token)
```

If a widget/read key is also in use, store it separately (e.g.
`USER_SIMPLYBOOK_APIKEY_READ_WIDGET`) so the name says which tier it is.

Make a long-running harness pick up the new vars by re-sourcing at call time:

```bash
set -a; source "$CLAUDE_HOME/.env"; set +a
```

---

## Using SimplyBook (after connecting)

**The admin token expires in 1 hour** — mint a fresh one at the start of each integration
session/run rather than persisting it. The token goes in the `X-User-Token` header (with
`X-Company-Login`) on every admin call:

```bash
set -a; source "$CLAUDE_HOME/.env"; set +a

# 1. Mint a fresh admin token (expires in 1 hour)
TOKEN=$(curl -s -X POST https://user-api.simplybook.me/login \
  -H "Content-Type: application/json" \
  -d "$(python3 -c 'import json,os; print(json.dumps({"jsonrpc":"2.0","method":"getUserToken","params":[os.environ["USER_SIMPLYBOOK_COMPANY_LOGIN"],os.environ["USER_SIMPLYBOOK_USER_LOGIN"],os.environ["USER_SIMPLYBOOK_APIKEY_RW_ADMIN"]],"id":1}))')" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])')

# 2. Call admin methods with that token
curl -s -X POST https://user-api.simplybook.me/admin/ \
  -H "Content-Type: application/json" \
  -H "X-User-Token: $TOKEN" \
  -H "X-Company-Login: $USER_SIMPLYBOOK_COMPANY_LOGIN" \
  -d '{"jsonrpc":"2.0","method":"getUnitList","params":[],"id":1}'
# writes use the same headers, e.g. "method":"addServiceProvider" / "editServiceProvider" / "setWorkDayInfo"
```

**What the admin tier unlocks:** provisioning/editing services, staff (service providers),
and working hours programmatically — the actual gap that otherwise blocks booking-setup
automation (with only the read-mostly widget key, any staff/hours/service change has to be
done by hand in the dashboard).

## Security

- The API User Key is sensitive builder access: store in `.env` (`chmod 600`), never in the
  repo, never in argv or shell history (pass via an env var / heredoc as shown).
- Keep it **local-only** — it is admin-tier and must never become a deployed site-runtime
  secret. Mint short-lived tokens from it per run rather than caching a token long-term.
- Follow the "Connected Accounts — READ-ONLY by default" rule: only run write methods
  (`add*` / `edit*` / `set*`) when the user has explicitly asked for that specific change.
