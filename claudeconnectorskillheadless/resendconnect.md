# Connecting Resend (transactional / customer-facing email)

A **Claude-driven** runbook for connecting **Resend** — a developer email service used
for **transactional / customer-facing email** (e.g. an automatic "thanks for reaching
out" reply after a website contact or reservation form). Resend is a **simple API key**
service: sign up, mint a key, optionally verify a sending domain over DNS, and store the
key. There is no OAuth app to create.

This is the headless, conversational replacement for a setup script: **Claude reads this
file and runs the flow itself**, one message at a time. It corresponds to
**connectorskill.md method #3 (simple API key / PAT)**. An optional remote-MCP layer for
interactive use is covered at the end — but the API key below is the credential everything
uses, so do the key steps first regardless.

> **Verify live — this drifts.** Resend's free-tier limits, key-permission names, and the
> exact DNS records it asks for change. Confirm against the Resend dashboard and
> `resend.com/docs` as you go; the values below are a starting point, not ground truth.

---

## Ground rules for Claude (read before starting)

- **Run interactively — never as a background / fire-and-forget job.** This flow needs the
  user to sign up and paste a key back. Drive it in a session that can receive the user's
  reply; a detached/background agent that only reports on completion will hang.
- **Drive it yourself, one step at a time.** Assume the user is **non-technical**. Send
  **one step**, **wait for the reply** before the next, keep each message short.
- **Never store a key in the repo.** Keys are sensitive — store in `.env` (`chmod 600`),
  never committed (see "Storing the keys" below).
- **Relay every URL as a tap-to-copy code span, not a clickable link** (a tap opens a
  full-screen in-app browser, hiding your steps). Send it on its own, wrapped in single
  backticks, with `format: "markdownv2"`. Details: `connectorskill.md` → "RELAYING LINKS
  OVER CHAT".

---

## Step 1 — User signs up for Resend

Resend has a free tier (no credit card, instant — **no manual approval gate**, which is why
it's the recommended transactional-email provider). Relay the signup link as its own
tap-to-copy send (the code block below **is** the literal `text` payload; send it with
`format: "markdownv2"`):

```
`https://resend.com/signup`
```

Ask the user to create the account (or sign in) and reply when they're in the dashboard.

## Step 2 — Create the API key(s) — CRITICAL PITFALL, read before creating one

The dashboard **defaults to a send-only "Restricted" key**. A restricted key **cannot
create/manage domains** via the API — confirmed live: `POST /domains` with a restricted key
returns `401 restricted_api_key`. **You must explicitly pick "Full Access" permission** when
creating a key if any domain work (adding/verifying a sending domain) is needed.

Decide which keys are needed:

- **Sending only, no custom domain yet** → one **Restricted (send-only)** key is enough.
- **Custom sending domain wanted** → use the **two-key least-privilege pattern**:
  1. a **Full-Access** key, used **once** for domain admin (Step 3) — keep it in `.env`
     local-only, **never deploy it** to a site or app.
  2. a separate **Restricted (send-only)** key for the actual runtime/site — that's the one
     that becomes the deployed secret.

Relay the API-keys page as a tap-to-copy send:

```
`https://resend.com/api-keys`
```

Tell the user to click **Create API Key**, pick the permission you told them (**Full Access**
for domain setup, **Sending access** for the runtime key), and paste each key back here.
**A Resend key is shown only once** — if they lose it they must create a new one. Wait for
the key(s).

## Step 3 — (Optional) Verify a sending domain — pure DNS, no mailbox needed

Skip this if the user only needs internal testing (see the "Until verified" note below).
Otherwise, for real customer-facing email from `@theirdomain`:

- Verifying a domain is DNS-based ownership + auth proof (SPF `TXT`, DKIM `TXT`, `MX` for
  bounce/feedback) — **no inbox/mailbox is required** to *send* from an address on that
  domain. A mailbox only matters if the domain must also *receive* mail (unrelated to
  sending).
- Resend recommends verifying a **subdomain** (e.g. `send.<domain>`) rather than the root
  domain, to protect the root domain's sender reputation.
- Create the domain with the **Full-Access** key (capture the key with a quoted heredoc so
  the shell does no expansion — treat it as untrusted input):

  ```bash
  IFS= read -r RESEND_FULL_KEY <<'EOF'
  <the Full-Access key the user sent>
  EOF
  curl -s -X POST https://api.resend.com/domains \
    -H "Authorization: Bearer ${RESEND_FULL_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"name":"send.<domain>"}'
  ```

  The response lists the exact DNS records to add (values are generated per-call,
  domain-specific).
- Add those records wherever the domain's DNS is managed (if that DNS is on a Cloudflare
  account the user has also connected, records can be added programmatically; otherwise give
  the user the exact records to paste in themselves), then **read back to confirm**.
- Verification is DNS-propagation-dependent (minutes to ~48–72h). Check status in the
  dashboard (Domains → the domain, "Pending" → "Verified") or `GET /domains/{id}`.
- **Status stuck at `not_started`? Don't assume the DNS is wrong.** `not_started` just means
  Resend hasn't run its check yet. Trigger a manual re-check first —
  `POST https://api.resend.com/domains/{id}/verify` (Full-Access key; cheap, safe,
  idempotent) — confirmed live to flip `not_started` → `pending` → `verified` in ~20s with
  zero DNS changes. Only do field-by-field record debugging if it's still stuck after that.
- **Until verified:** sends only work from the shared `onboarding@resend.dev` address and
  only **to the account owner's own verified email** — fine for internal testing, **not**
  usable for real customer-facing email. Say this plainly so nobody assumes it's launch-ready
  before verification actually completes.

## Step 4 — Validate a key live (do not skip)

Before storing, confirm the runtime (send) key actually works. Capture it with a quoted
heredoc and hit a read endpoint:

```bash
IFS= read -r RESEND_KEY_INPUT <<'EOF'
<the key to validate>
EOF
curl -s -o /tmp/resend_check.json -w '%{http_code}' \
  https://api.resend.com/domains \
  -H "Authorization: Bearer ${RESEND_KEY_INPUT}"
```

- **`200`** → valid. (A restricted send-only key may return `200` with an empty list, or
  `401 restricted_api_key` on `/domains` specifically — that `401` still proves the key
  authenticates; it just lacks domain scope, which is expected for the send key.)
- **`401 invalid_api_key` / missing** → bad key; ask the user to re-check and resend
  (back to Step 2). Do **not** store an unvalidated key.

(Clean up `/tmp/resend_check.json` afterward.)

## Step 5 — Store the keys

Store in `.env` (`chmod 600`, never committed), named per `storingsecrets.md`
(`<OWNER>_<SERVICE>_<TYPE>_<MODE>_<RESOURCE>`; `<OWNER>` = `USER` for the user's account).
Keep the two keys distinct so the name says how to use each:

```
USER_RESEND_APIKEY_RW_ADMIN=<Full-Access key>     # one-time domain admin — NEVER deploy
USER_RESEND_APIKEY_SEND_RUNTIME=<Restricted key>  # send-only — the one apps/sites use
```

If only one send-only key was created, store just the runtime line. The Full-Access key is
optional and only needed again to add/verify another domain.

## Step 6 — Make the running process see the new key

A long-running harness that loaded `.env` at startup won't see a newly added variable.
Read it from `.env` at call time instead of relying on the inherited env:

```bash
set -a; source "$CLAUDE_HOME/.env"; set +a   # picks up the RESEND keys just written
```

---

## Using Resend (after connecting)

Send with the **send-only runtime** key over plain REST:

```bash
set -a; source "$CLAUDE_HOME/.env"; set +a
curl -s -X POST https://api.resend.com/emails \
  -H "Authorization: Bearer $USER_RESEND_APIKEY_SEND_RUNTIME" \
  -H "Content-Type: application/json" \
  -d '{"from":"<verified-address>","to":"<recipient>","subject":"...","html":"..."}'
```

- Use a verified sending address once Step 3 completes; before that only `onboarding@resend.dev`
  → the owner's own email works.
- **Resend is send-only** — there is no human-readable mailbox to check. Confirmations land in
  the recipient's normal email client; nothing new for the owner to log into.
- **Fail-safe in app code:** if a send errors, don't block or lose the user's action over it —
  log the failure and continue (e.g. a form submission should still succeed even if the
  confirmation email fails).

## Optional — Resend as a claude.ai custom connector (interactive agent use)

If the user wants Claude to send email / manage contacts and domains **conversationally**
(not from deployed app code), Resend also runs an official **remote MCP server** at
`https://mcp.resend.com/mcp`. It authenticates with the **same Resend API key** as a Bearer
token (or OAuth), and exposes the full API (emails, contacts, broadcasts, domains, webhooks,
…) — R+W. Add it in **claude.ai → Settings → Connectors → Add custom connector**, URL
`https://mcp.resend.com/mcp`, with an `Authorization: Bearer <key>` header (use a key scoped
to what the agent should do). This is an **optional layer on top of** the API key above — the
key is still the credential — and requires a restart / `/mcp` refresh before it appears
(see `connectorskill.md` → "#1 — Official claude.ai connector", restart note). For sending
from a deployed site/app, the direct REST call above is what's used, not the MCP.

## Security

- Keys are sensitive: store in `.env` (`chmod 600`), never in the repo, never in argv or
  shell history (pass via an env var / heredoc as shown).
- **Least privilege:** deploy only the **send-only** key to any site/app; keep the
  **Full-Access** key local-only and use it just for one-time domain admin. Rotate (recreate)
  any key that leaks.
