# Storing credentials (one service, many keys)

How a Claude harness should store the tokens / keys / PATs it obtains when
connecting a service (see `connectorskill.md` for the connection methods themselves). These
scripts **store nothing** — they emit a `credentials` event on stdout and **you
(Claude) store it**. This file is the single source of truth for *how*.

## Principle

A service often needs **several** credentials for different scopes/resources (e.g.
GitHub: a read-only PAT, a read+write PAT per repo, an org-admin PAT). Store them so
each is **individually rotatable** and Claude can **pick the right one per task** —
with **no separate index file to maintain**. The env-var **name carries everything
needed to choose it**; the only state is `.env` itself.

## 1. One secret per env var; the name encodes how to pick it

`<OWNER>_<SERVICE>_<TYPE>_<MODE>_<RESOURCE>`, uppercase, `[A-Z0-9_]` only (sanitize a
resource like `acme/web` → `ACME_WEB`; use `ALL` for account-wide). The leading
**`<OWNER>`** is **`USER`** (the user's own account) or **`SERVICE`** (the agent's own
dedicated account) — it is **required** and is the first thing that disambiguates a
credential; see §4. One value per var — never cram several into one, never a JSON blob
of secrets. `.env` allows `#` comments — annotate each with anything the name can't
hold (e.g. exact scopes).

**Multi-account / per-resource services (e.g. GitHub).** When a service can hold more than
one account, or scopes a credential to a specific resource, the name must pin down **both
the account and the resource owner**:

- **Account login goes in the name**, right after `<OWNER>`: `<OWNER>_<LOGIN>_<SERVICE>_…`
  (the GitHub username, sanitized) — always, even for a single account, so two accounts can
  never collide.
- **The resource owner goes in the name too.** `<RESOURCE>` is the fully-qualified
  `owner/repo` (`acme/web` → `ACME_WEB`), because the repo's owner can be an **org** that
  differs from the token holder's login — e.g. `USER_OCTOCAT_…_RW_ACME_WEB` is octocat's token
  for the **acme** org's `web` repo. The GitHub naming scheme is therefore
  `USER_<LOGIN>_GITHUB_PAT_<MODE>_<REPO_OWNER>_<REPO_NAME>`.

- **The name is for selection; a mandatory `#` comment is the source of truth.** Uppercasing
  is lossy (`a.b`/`a-b`/`a_b` all → `A_B`) and a multi-repo label (`ACME_MULTI`) can't be
  split back, so the name only *approximates* the target. **Every such credential MUST carry
  one inline `#` comment** recording the exact, name-can't-hold facts in a fixed order — for
  GitHub: `# <fine-grained|CLASSIC>; <exact-login>; repos: <owner/repo>[, …] | ALL; perms:
  <list>` — for an **org-scoped** token (no specific repos) replace the `repos:` field with
  `org: <org>`. Leave **≥1 space before `#`** so loaders strip it from the value (§1, last para).

```
# .env  (chmod 600, never committed) — GitHub: USER_<LOGIN>_GITHUB_PAT_<MODE>_<OWNER>_<REPO>
USER_OCTOCAT_GITHUB_PAT_RO_ALL=github_pat_...      # fine-grained; octocat; repos: ALL (account-wide, read); perms: metadata=RO
USER_OCTOCAT_GITHUB_PAT_RW_ACME_WEB=github_pat_... # fine-grained; octocat; repos: acme/web (org repo, owner ≠ login); perms: contents,pull_requests=RW
USER_OCTOCAT_GITHUB_PAT_ADMIN_ACME_ORG=github_pat_... # fine-grained; octocat; org: acme (ADMIN — sensitive, avoid by default); perms: administration=RW
```

Claude selects by **reading the key names alone** — `USER_OCTOCAT_GITHUB_PAT_RW_ACME_WEB`
already says "octocat's GitHub PAT, read+write, repo acme/web." (Grep the names, not values.)
But the name only *approximates* the target — the **exact** login and `owner/repo` live in the
**`#` comment**, because uppercasing is lossy and a multi-repo label can't be parsed back.
Read the comment before acting on a specific repo. (A non-secret `_LOGIN` companion var is
optional, only when a process needs the exact login programmatically.)

**Quote any value that contains a space** (or `#`, `$`, or a quote). A `.env` is
commonly loaded by shell-`source`ing it, where an unquoted `KEY=a b` is read as
"run command `b` with `KEY=a` in its env" — so the value is truncated at the first
space and, depending on the loader, the line may error and abort loading the whole
file. **Single-quote** such values: `KEY='a b c'`. If a value itself contains a
single quote, wrap it in double quotes instead (e.g. `KEY="value's"`) — the
bash-style `'\''` escape is not understood by many `.env` parsers (Node `dotenv`,
`python-dotenv`). The common case is a space-separated OAuth `scopes` list (see §3) —
store it single-quoted; the value itself is unchanged, only its encoding. Most
tokens/keys/ids have no spaces and need no quoting, but when in doubt, quote.

## 2. Selection rule

For a task, use the **least-privileged** name that covers it (read → an `_RO_` key;
write to acme/web → `USER_OCTOCAT_GITHUB_PAT_RW_ACME_WEB`). Prefer a resource-scoped name over
an account-wide `_ALL`; avoid `_ADMIN_` keys unless required.

## 3. OAuth bundles

An OAuth credential is several values. Keep them together by **sharing one prefix** —
the prefix *is* the index. The secrets are `<SVC>_<PURPOSE>_ACCESS_TOKEN` /
`_REFRESH_TOKEN` / `_CLIENT_SECRET`; store the non-secret companions (`client_id`,
`token_endpoint`, `resource`, `scopes`) as sibling vars under the **same prefix** so
they travel together by name:

```
# The USER's own Google Ads (USER_ owner prefix — see §4)
USER_GOOGLE_ADS_RW_ACCESS_TOKEN=ya29....                              # secret
USER_GOOGLE_ADS_RW_REFRESH_TOKEN=1//....                              # secret
USER_GOOGLE_ADS_RW_CLIENT_SECRET=GOCSPX-...                           # secret
USER_GOOGLE_ADS_RW_CLIENT_ID=...apps.googleusercontent.com           # non-secret
USER_GOOGLE_ADS_RW_TOKEN_ENDPOINT=https://oauth2.googleapis.com/token # non-secret
USER_GOOGLE_ADS_RW_SCOPES='https://www.googleapis.com/auth/adwords https://www.googleapis.com/auth/userinfo.email'  # non-secret — space-separated, single-quote it (see §1)
```

**`scopes` is a space-separated list, so it MUST be single-quoted** (as above) —
unquoted, the spaces break shell-`source`ing of the file (§1). The secrets and the
other companions are single tokens and need no quoting.

To refresh, read the sibling vars sharing the `USER_GOOGLE_ADS_RW_` prefix and call
`refresh.mjs`. The scripts' `credentials` event gives you exactly these fields —
store each as its own prefixed var.

> The `USER_GOOGLE_ADS_RW_*` bundle above is a **user** account (the user's own Google
> Ads) — hence the `USER_` prefix, not `SERVICE_` (see §4). Even though it's an OAuth
> bundle named `RW`, the harness should default to **read-only** on it.

## 4. Owner prefix — `USER_` vs. `SERVICE_` (always required)

A connected account is one of two very different things, and the **first** field of
every credential name (`<OWNER>`, §1) must make clear **which**:

- **`SERVICE_` — agent-owned.** A *dedicated* account the harness controls outright
  (e.g. its own Google Workspace / service email). The agent **is** the account
  holder, so full read/write is expected.
- **`USER_` — the user's.** Their real Google Ads, GitHub, HubSpot, etc. The agent is
  acting *on someone else's account* and should treat it as **read-only by default**,
  writing only when the user explicitly asks.

Every connected-account var carries one of these two prefixes — never omit it, so a
user credential can never be mistaken for a service one (and vice-versa):

```
# Agent's OWN dedicated Google Workspace (full read/write — it's Claude's account)
SERVICE_GOOGLE_WORKSPACE_RW_ACCESS_TOKEN=ya29....                              # secret
SERVICE_GOOGLE_WORKSPACE_RW_REFRESH_TOKEN=1//....                              # secret
SERVICE_GOOGLE_WORKSPACE_RW_CLIENT_SECRET=GOCSPX-...                           # secret
SERVICE_GOOGLE_WORKSPACE_RW_CLIENT_ID=...apps.googleusercontent.com           # non-secret
SERVICE_GOOGLE_WORKSPACE_RW_TOKEN_ENDPOINT=https://oauth2.googleapis.com/token # non-secret
SERVICE_GOOGLE_WORKSPACE_RW_SCOPES='https://www.googleapis.com/auth/gmail.modify ...' # non-secret — quote it (§1)
SERVICE_GOOGLE_WORKSPACE_RW_EMAIL=<the dedicated account's address>           # non-secret

# The USER's own accounts — USER_ prefix; read-only by default
USER_GOOGLE_ADS_RW_*                  # the user's Google Ads
USER_OCTOCAT_GITHUB_PAT_RW_ACME_WEB   # octocat's token → repo acme/web (login in name; see §1)
```

The prefix is the at-a-glance signal: `SERVICE_…` = "the agent's own account — safe to
act on freely"; `USER_…` = "the user's account — read by default, write only when
explicitly asked." `refresh.mjs` and every API call just read the sibling vars under
whichever prefix applies.

## Security

Never write tokens/keys/PATs/client-secrets into the repo. Store in `.env`
(`chmod 600`), named per service per the conventions above. Request least-sufficient
scopes (see `connectorskill.md` #3/#4). Treat the `credentials` event as sensitive.
