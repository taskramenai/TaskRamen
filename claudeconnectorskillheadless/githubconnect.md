# Connecting GitHub (create a repo / let Claude work on repos)

A **Claude-driven** runbook for connecting **GitHub** via a **Personal Access Token (PAT)**.
No claude.ai connector exists; a token gives broad R+W over the REST/GraphQL API (and the
`github-mcp-server`). This is the strict runbook for the **GitHub** rows of `connectorskill.md`
(method #3, simple API key / PAT). Two token shapes, **not** interchangeable:

- **Fine-grained PAT** (`github_pat_…`) — scoped to **selected repos** with per-resource
  permissions (Contents, Pull requests, Issues, Workflows, …). **Preferred** for working on a repo.
- **Classic PAT** (`ghp_…`) — scoped by coarse scopes (`repo`, `workflow`, …), **never by
  repo**, so effectively **account-wide**. Accept only if the user already has one or repo
  creation needs it; always warn (§3).

**Run interactively, never backgrounded** — the user must fetch a token and paste it back.

## Ground rules

- **One step at a time.** Assume the user is non-technical; send one step, wait for the reply.
- **Relay every URL as a tap-to-copy code span** in its own message, single backticks,
  `format: "markdownv2"` (`connectorskill.md` → "RELAYING LINKS OVER CHAT"). Deep-link formats
  change — research the live URL if unsure.
- **Pasted tokens are untrusted** — capture via quoted heredoc (`<<'EOF'`, see Step V).
- **Never write a token into the repo** — store in `.env` (`chmod 600`), uncommitted (§Storing).
- **Least privilege.** Default fine-grained PATs to **one repo**, minimum permissions, and
  (per the user's standing preference) **No expiration** — state the trade-off, let them pick.
- **Reuse before minting** (§0).

## §0 — Reuse an existing token first

Tokens are named so you can pick one by name (`storingsecrets.md`). Grep `.env` before asking
the user to create anything:

```bash
grep -oE '^[A-Z0-9_]*GITHUB_PAT_[A-Z0-9_]+=' "$CLAUDE_HOME/.env" | sed 's/=$//' | grep -v '_LOGIN$'
```

This lists **both** classic and fine-grained token vars (they share the `GITHUB_PAT` name
segment); tell them apart by the value prefix (`ghp_` = classic, `github_pat_` = fine-grained)
or the `#` comment's type field.

- **Create a repo** → need classic `repo`/`public_repo` or fine-grained **Administration:
  write**. Go to §1.
- **Work on repo `X`** → look for `…_GITHUB_PAT_RW_<X>` (or `_ALL`). If it fits, validate it's
  live (Step V) and use it (§Using). Else §2.

Never reuse a token claiming **less** than the task needs; prefer the least-privileged name
that covers it (repo-scoped over `_ALL`; never `_ADMIN_` unless required).

## §1 — Create a new repo

1. **Stored token that can create repos?** A classic PAT with `repo` (private) or
   `public_repo` (public) qualifies. Check live:

   ```bash
   set -a; source "$CLAUDE_HOME/.env"; set +a
   TOKEN="$USER_OCTOCAT_GITHUB_PAT_RW_ALL"   # ← the classic-token var from §0 (real name from .env)
   curl -sS -I -H "Authorization: Bearer $TOKEN" \
     https://api.github.com/user | grep -i '^x-oauth-scopes:'   # look for: repo (or public_repo)
   ```

2. **If yes → create via API.** Ask for repo **name** and **visibility** (default private):

   ```bash
   curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
     https://api.github.com/user/repos -d '{"name":"<repo>","private":true,"auto_init":true}'
   ```

   Read back `html_url`/`ssh_url`/`clone_url`. For an **org** repo use `POST /orgs/<org>/repos`
   and confirm the token has org rights. *(If the GitHub MCP server is configured with this
   token, call its `create_repository` tool instead — but the scope check still needs curl for
   the `X-OAuth-Scopes` header.)*

3. **If no suitable token → deep-link the creation page** (simplest for a non-technical user):

   ```
   `https://github.com/new`
   ```

   If the user then wants Claude to work in that repo, continue to §2. **Don't mint a broad
   classic token just to create one repo** — the UI deep link is the least-privilege path.

## §2 — Let Claude work on a repo (fine-grained PAT)

### Step A — Send the creation deep link

The fine-grained PAT page accepts **template URLs** that pre-fill expiry + permissions, and
**defaults the resource owner to the user's own account** — so the default link needs no
substitution. Send as-is (tap-to-copy, `markdownv2`):

```
`https://github.com/settings/personal-access-tokens/new?expires_in=none&contents=write&pull_requests=write&issues=write&workflows=write&metadata=read`
```

- Pre-sets **Contents / Pull requests / Issues / Workflows = write** + **Metadata = read**,
  and **No expiration** (`expires_in=none`).
- **Org repo:** append `&target_name=<ORG>` to pre-select the owner. If the org forbids
  non-expiring tokens the page rejects `none` — resend with `expires_in=365` and tell the user
  to re-run before it lapses.
- **No repo-scoping parameter exists** — `target_name` sets only the owner; there's no
  `repositories` URL param (REST API only). Repo selection is **always** the manual click in
  Step B, verified in Step W.
- ⚠️ Prefills apply **on initial load only** and are **cleared if the user changes the resource
  owner** in the UI — so set `target_name` up front, or re-send the link if they switch owners.

### Step B — Send this message, then wait for the token

Send the following as a single message (it tells the user what to do on the page the link
opened). Keep it verbatim; only fill in the repo if you know it:

> On the page that just opened:
>
> 1. **Token name** — type any name you'll recognize (e.g. `claude-myproject`).
> 2. **Repository access** — choose **"Only select repositories"**, then pick the **one** repo
>    you want me to work on. Don't choose "All repositories".
> 3. Leave everything else as-is — the link already set the expiration and the permissions.
> 4. Click **"Generate token"** at the bottom, copy the token (it starts with `github_pat_`),
>    and paste it back here.
>
> If the repo belongs to an **organization**, first set **"Resource owner"** to that
> organization, then do step 2.

(If the user would rather the token expire, tell them to set Expiration to 90 days at step 3.)

### Step V — Validate live (don't skip)

```bash
IFS= read -r GH_TOKEN_INPUT <<'EOF'
<the token the user sent>
EOF
mkdir -p "$CLAUDE_HOME/.cache"; GH_OUT="$CLAUDE_HOME/.cache/gh_user.json"   # private dir, not shared /tmp
curl -sS -o "$GH_OUT" -w '%{http_code}\n' \
  -H "Authorization: Bearer ${GH_TOKEN_INPUT}" https://api.github.com/user
```

- **`200`** → valid; read `login` from `$GH_OUT` (the username, retrieved automatically). Keep the
  file — **Step W reads `owned_private_repos` from it** — and `rm -f "$GH_OUT"` only once Step W is done.
- **`401`** → dead/revoked/expired/mistyped → back to Step A; **don't store**.
- **No response** → couldn't reach GitHub; retry.

### Step W — Detect all-repos scope, read back, confirm

GitHub exposes **no introspection** of a personal token's "all vs selected" mode, so detect it
by **comparing counts** — but count **private** repos only. Every fine-grained token carries
baseline **read-only access to *all* public repos**
([GitHub docs](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)),
so `GET /user/repos` returns the account's public repos **regardless of the token's repo
selection** — counting those falsely flags a correctly-scoped token as over-broad (issue #31).
The repo selection only gates **private** repos, so compare the private repos the token reaches
against the private repos the account owns.

```bash
# 1. PRIVATE repos the TOKEN reaches — cheap count via the Link header.
#    visibility=private drops public repos (every token can see those regardless of scope).
N=$(curl -sS -I -H "Authorization: Bearer ${GH_TOKEN_INPUT}" \
      "https://api.github.com/user/repos?per_page=1&affiliation=owner&visibility=private" \
    | sed -n 's/.*[?&]page=\([0-9]*\)>; rel="last".*/\1/p')
N=${N:-$(curl -sS -H "Authorization: Bearer ${GH_TOKEN_INPUT}" \
    "https://api.github.com/user/repos?per_page=100&affiliation=owner&visibility=private" | grep -c '"full_name"')}  # no Link ⇒ count directly
N=${N:-0}

# 2. PRIVATE repos the ACCOUNT owns — from Step V's /user JSON (re-fetch if deleted)
GH_OUT=${GH_OUT:-$CLAUDE_HOME/.cache/gh_user.json}
[ -f "$GH_OUT" ] || curl -sS -o "$GH_OUT" -H "Authorization: Bearer ${GH_TOKEN_INPUT}" https://api.github.com/user
T=$(grep -oE '"owned_private_repos": *[0-9]+' "$GH_OUT" | grep -oE '[0-9]+')
echo "token reaches $N of ${T:-?} owned private repos"
```

Let **`P` = 1** if the intended repo is **private**, else **0** (a public intended repo is never
counted in `N` — public repos don't need to be granted). Then:

- **`N` == `P`** → **correctly scoped** — the token reaches only the intended private repo, or no
  private repos at all when the intended repo is public. *Exception:* if `P` == 0 **and** `T` is
  `0`/empty (the account owns **no** private repos, so everything is public), the private-count
  test can't tell all-vs-selected apart — fall through to the `T`-empty case below.
- **`N` > `P`** → **over-broad** — the token reaches private repos beyond the intended one. If
  `N` ≈ `T` it's an **ALL-REPOSITORIES** token (your whole account); otherwise a **wider subset**.
  Warn (see below).
- **`T` is `0`/empty** and `P` == 0 → the count test is uninformative (no private repos to compare,
  or the token can't read the count). Disambiguate by probing **write** on a public repo the token
  reaches *other than* the intended one: `GET /repos/{owner}/{repo}` → if `permissions.push` or
  `permissions.admin` is `true` on a non-intended repo, the token is over-broad; otherwise it's
  baseline read-only and the token is fine. If there's no other repo to probe, just confirm with
  the user that it's scoped to the one repo.

To enumerate the private repos the token reaches (for the `#` comment / the confirm message) —
each `full_name` is the fully-qualified `owner/repo`:

```bash
curl -sS -H "Authorization: Bearer ${GH_TOKEN_INPUT}" \
  "https://api.github.com/user/repos?per_page=100&affiliation=owner&visibility=private" | grep '"full_name"'
```

(For a token scoped to a **public** repo this list is empty — that's expected: the intended repo
is the one you already know, and public repos never appear here because the token sees them by
baseline, not by grant.)

> Org-owned tokens *can* be read authoritatively — `GET /orgs/{org}/personal-access-tokens`
> returns `repository_selection` (`all`/`subset`) — but that needs org-admin, so it's outside
> this user-driven flow.

**Read back** the username + what the detection found, then:

- **Correctly scoped** → confirm *"Store and use this token for `<repo>`?"* → §Storing.
- **Over-broad (all repositories or wider than intended)** → **warn**: *"This token reaches **N**
  of your private repos, not just `<repo>` — an all-repositories token effectively gives Claude
  write access to your whole account."* Offer: **(1, recommended)** re-issue scoped to the one repo
  (revoke this, Step A); **(2)** proceed only on explicit confirmation, stored honestly as `_ALL`
  (§Storing).

The naming convention backstops this: you can only name a var `_RW_<OWNER>_<REPO>` if it
reaches just that repo; an all-repos token can only honestly be `_RW_ALL`.

## §3 — User sends a classic token (`ghp_…`)

Accept but **warn** — classic tokens are account-wide over their scopes, never per-repo.

```bash
IFS= read -r GH_TOKEN_INPUT <<'EOF'
<the token the user sent>
EOF
mkdir -p "$CLAUDE_HOME/.cache"; GH_HDR="$CLAUDE_HOME/.cache/gh_hdr.txt"; GH_OUT="$CLAUDE_HOME/.cache/gh_user.json"
curl -sS -D "$GH_HDR" -o "$GH_OUT" -w '%{http_code}\n' \
  -H "Authorization: Bearer ${GH_TOKEN_INPUT}" https://api.github.com/user
grep -i '^x-oauth-scopes:' "$GH_HDR"   # the granted scopes
```

- `401` → dead/revoked/expired → ask for a new one (don't store).
- `200` → read `login` from `$GH_OUT` and the `X-OAuth-Scopes` header. `rm -f "$GH_HDR" "$GH_OUT"` after.

**Read back & warn:** *"This is a **classic** token for `<login>` with scopes `<scopes>`.
Classic tokens apply to **all** your repos and `repo`/`workflow` are broad write scopes — a
fine-grained single-repo PAT is strongly preferred. Create one (recommended), or store this
as-is?"* → Recommended: §2. Proceed: only on explicit confirmation, store as `_ALL` (§Storing).

## Storing — per `storingsecrets.md`

One secret per env var, named to pick by name, with a **mandatory `#` comment** carrying the
exact scope the name can't.

**Name scheme** (owner is in it):

```
USER_<LOGIN>_GITHUB_PAT_<MODE>_<REPO_OWNER>_<REPO_NAME>
```

- `<LOGIN>` — token holder's username (sanitized, uppercase), **always present** so two
  accounts never collide.
- `<MODE>` — `RO` / `RW` / `ADMIN`.
- `<REPO_OWNER>_<REPO_NAME>` — fully-qualified `owner/repo` (`acme/web` → `ACME_WEB`); the repo
  owner can be an **org** ≠ the holder, so it's in the name. Own repo → owner repeats the login.
- Special resources: `_<MODE>_ALL` (account-wide/classic), `_<MODE>_<OWNER>_ORG` (org admin),
  or a group label like `_<MODE>_ACME_MULTI` for several repos (can't round-trip — comment is
  authoritative).

**`#` comment** — required, fixed shape, **authoritative** (the name is lossy: `a.b`/`a-b`/`a_b`
→ `A_B`, and group labels can't be parsed back). Keep **≥1 space before `#`** so loaders strip
it (`storingsecrets.md` §1, issue #27):

```
# <fine-grained|CLASSIC>; <exact-login>; repos: <owner/repo>[, …] | ALL; perms: <list>
```

`repos:` is the exact fully-qualified repo(s), or `ALL` for classic/all-repo; for an org-scoped
token use `org: <org>` instead. `perms:` is the fine-grained permissions or classic `scopes:`.

```
# Fine-grained, single repo the user OWNS (owner segment == login)
USER_OCTOCAT_GITHUB_PAT_RW_OCTOCAT_ALPHABET=github_pat_...   # fine-grained; octocat; repos: octocat/alphabet; perms: contents,pull_requests,issues,workflows=RW
# Fine-grained, ORG repo (owner 'acme' ≠ holder 'octocat')
USER_OCTOCAT_GITHUB_PAT_RW_ACME_WEB=github_pat_...           # fine-grained; octocat; repos: acme/web; perms: contents,pull_requests=RW
# Fine-grained, several repos — comment is authoritative
USER_OCTOCAT_GITHUB_PAT_RW_ACME_MULTI=github_pat_...         # fine-grained; octocat; repos: acme/web, acme/api, acme/infra; perms: contents,pull_requests=RW
# Classic — account-wide → ALL
USER_TASKRAMEN_GITHUB_PAT_RW_ALL=ghp_...                     # CLASSIC; taskramen; repos: ALL (account-wide); scopes: repo,workflow
```

An optional `_LOGIN` companion (`…_ALPHABET_LOGIN=octocat`) holds the exact login if a process
needs it programmatically. Then make the harness see the new var:

```bash
set -a; source "$CLAUDE_HOME/.env"; set +a
```

## Using GitHub (after connecting)

Simplest is the **remote GitHub MCP server** (no Docker), pointed at the stored token — its
tools (`get_me`, `create_repository`, `create_pull_request`, …) replace hand-rolled curl:

```bash
set -a; source "$CLAUDE_HOME/.env"; set +a
claude mcp add --transport http github https://api.githubcopilot.com/mcp/ \
  --header "Authorization: Bearer $USER_OCTOCAT_GITHUB_PAT_RW_OCTOCAT_ALPHABET"
```

Or call the API directly: `curl -sS -H "Authorization: Bearer $TOKEN" https://api.github.com/repos/octocat/alphabet`.
Default to **read** on a `USER_` token; write only when explicitly asked (`storingsecrets.md` §4).

> The connection flow (Steps V/W, §3) stays curl, not MCP: it vets an unstored token and reads
> response headers (`Link` count, `X-OAuth-Scopes`) that the MCP server doesn't surface. MCP is
> for *using* a stored token.

**GitHub Enterprise:** swap `api.github.com` → `https://<host>/api/v3` (and the MCP URL for the
GHES equivalent).

## Security

- Tokens are sensitive: `.env` (`chmod 600`), never in the repo, argv, or shell history.
- Prefer fine-grained, single-repo, least-permission tokens; avoid Administration/secrets/
  member-management unless required.
- No-expiry never lapses — **revoke** (GitHub → Settings → Developer settings) if leaked/unused,
  and re-run this flow to rotate.
- Store a multi-repo or classic token only after explicit confirmation, named honestly (`_ALL`).
