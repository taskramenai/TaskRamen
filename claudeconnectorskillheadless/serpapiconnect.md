# Connecting SerpAPI (Google Search / Flights / Maps as search data)

A **Claude-driven** runbook for connecting **SerpAPI** — a simple, long-lived
**API key** that unlocks Google Search, Flights, Hotels, Maps, Finance, News, and
other engines over **direct HTTPS REST**. This is *search data*, **not** an account
connection: there is no OAuth, no app to create, and no scripts to run — just
obtain a key, validate it, and store it.

This is the headless, conversational replacement for a setup script: **Claude reads
this file and runs the flow itself**, talking the user through it one message at a
time. It corresponds to **connectorskill.md method #3 (simple API key / PAT)** and to
the Google disambiguation case **(e) Google Search / Flights / Maps → SerpAPI**.

---

## Ground rules for Claude (read before starting)

- **Run interactively — never as a background / fire-and-forget job.** This flow
  needs the user to fetch a key and paste it back. Drive it in a session that can
  receive the user's reply; a detached/background agent that only reports on
  completion will hang.
- **Drive it yourself, one step at a time.** Assume the user is **non-technical**.
  Send **one step**, **wait for the reply** before the next, keep each message short.
- **Never store the key in the repo.** It is sensitive — store it in `.env`
  (`chmod 600`), never committed (see "Storing the key" below).
- **Relay the signup URL as a tap-to-copy code span, not a clickable link** (a tap opens
  a full-screen in-app browser, hiding your steps). Send it on its own, wrapped in single
  backticks, with `format: "markdownv2"`. Details: `connectorskill.md` → "RELAYING LINKS
  OVER CHAT".

---

## Step 1 — User gets a SerpAPI key

Tell the user SerpAPI has a free tier; they need an account and their API key. Relay the
signup link as its own tap-to-copy send — the `code block` below already includes the
backticks and **is** the literal `text` payload; send it with `format: "markdownv2"`:

```
`https://serpapi.com/users/sign_up`
```

Then: sign up (or sign in), open the dashboard → **Your Account / API Key**, copy the
key, and paste it back here. If they need the key page directly, send it the same way:

```
`https://serpapi.com/manage-api-key`
```

Wait for the user to send the key.

## Step 2 — Validate the key live (do not skip)

Never trust a pasted key — verify it against SerpAPI's account endpoint before
storing. Treat the key as **untrusted input**: capture it with a **quoted heredoc**
(`<<'EOF'`) so the shell performs no expansion, no command substitution, and there
is nothing on the command line to inject into — pasting the raw value into a
quoted assignment would break out of the quoting if the key contained a `'`:

```bash
IFS= read -r SERPAPI_KEY_INPUT <<'EOF'
<the key the user sent>
EOF
curl -s -o /tmp/serpapi_account.json -w '%{http_code}' \
  "https://serpapi.com/account?api_key=${SERPAPI_KEY_INPUT}"
```

- **HTTP `200`** → valid. Read `plan_searches_left` (and `total_searches_left`) from
  `/tmp/serpapi_account.json` and tell the user how many searches remain.
- **Any non-200** (typically `401`) → invalid/expired key. Read the `error` field
  from the JSON, tell the user plainly, and ask them to re-check and resend (back to
  Step 1). Do **not** store an unvalidated key.
- **No response / network error** → could not reach SerpAPI; ask the user to retry.

(Clean up `/tmp/serpapi_account.json` afterward.)

## Step 3 — Store the key

SerpAPI issues **one account-wide key**, so a single env var suffices. Store it in
`.env` (`chmod 600`, never committed) as:

```
SERPAPI_KEY=<validated key>        # SerpAPI — Google Search/Flights/Maps/Finance, account-wide
```

`SERPAPI_KEY` is the conventional name harnesses read for direct REST calls. For the
general naming scheme (and when a service needs several scoped keys) see
`storingsecrets.md`.

## Step 4 — Make the running process see the new key

A long-running harness that loaded `.env` at startup will **not** see a newly added
variable in its inherited environment. The simplest fix is to **read the key from
`.env` at call time** rather than rely on the inherited env — then the key works
immediately, no restart required:

```bash
set -a; source "$CLAUDE_HOME/.env"; set +a   # picks up SERPAPI_KEY (and anything else just written)
```

Restart the harness process only if re-sourcing `.env` per call isn't an option.

---

## Using SerpAPI (after connecting)

All engines are plain REST `GET`s with `api_key=$SERPAPI_KEY`. Source `.env` in the
same command so the key is always current (see Step 4):

```bash
set -a; source "$CLAUDE_HOME/.env"; set +a
# Web search
curl -s "https://serpapi.com/search?engine=google&q=<query>&api_key=$SERPAPI_KEY"
# Other engines: engine=google_flights | google_maps | google_finance | google_news | …
```

Parse large JSON responses with `jq`/Python from a saved file rather than reading
them raw. No MCP or allowlist is needed — it is direct REST with the stored key.

## Security

- The key is sensitive: store it in `.env` (`chmod 600`), never in the repo, never in
  argv or shell history (pass via an env var as in Step 2).
- A single account-wide key carries the account's full quota — treat it like any
  other secret and rotate it (re-run this flow) if it leaks.
