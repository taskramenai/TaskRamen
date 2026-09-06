---
name: website-builder
description: Build and manage SME websites end-to-end on the Cloudflare + Astro stack. Use when the user wants to build, deploy, or manage a small-business website — both brand-new builds and taking over / continuing an existing site.
---

# Website Builder

## Overview / when to use

Use this skill whenever the user wants to **build, deploy, or manage an SME (small/medium enterprise) website** — from first conversation to a live site on a custom domain, plus ongoing management; covers **new builds AND existing sites** (built by someone else, or started in an earlier session). You are running a repeatable system (standardized stack, reusable templates, scripted pipeline), not hand-coding each site — for existing sites it adapts to what's actually there (Step 0).

**Terminology:** **"the user"** = the person you're chatting with (your operator / often the SME owner); **"the client"** = the SME whose site + business tools these are (in a solo-SME job they're the same person). **`<PROJECT>`** = the project's identifier used as the env-var prefix, e.g. `ACME_CO` → `ACME_CO_CLOUDFLARE_API_TOKEN`.

**Reference files (in this directory):**
- `tina-cloud-setup.md` — the default CMS: build-time wire-in (14a) + activation walkthrough (14b), `tina/config.ts` template, env vars, reindex quirk.
- `keystatic-appendix.md` — alternative self-hosted CMS, only when the owner wants no third-party account.
- `business-tools.md` — Part 2: CRM / payments / e-commerce / scheduling integrations, keyed to the SME taxonomy.

**Operational rules (enforce throughout):**
- **FOREGROUND workflow, BACKGROUND build tasks.** The main workflow is **interactive** — the user replies between steps over Telegram (choices, pasted tokens, confirmations, design feedback) — so run it in the **MAIN session, foreground**, like connector flows (an interactive-flow exception to the global "Background Agents — MANDATORY" rule; a detached agent can't receive replies). Every **"run foreground"** tag in this skill and its reference files means exactly this. Spawn **background agents only for discrete, self-contained tasks needing no mid-task user input** (building the site code, pushing + verifying a deploy, analyzing a codebase), following the global background-agent rules ("⚙️ Starting a background agent…" message, milestones via `edit_message`, completion via a new `reply`).
- **ALL service connections go through the connector skill.** Whenever Cloudflare, GitHub, HubSpot (or any service) needs connecting or a credential minted, **read and follow `claudeconnectorskillheadless/connectorskill.md`** (and the per-service runbooks it names, e.g. `claudeconnectorskillheadless/githubconnect.md`) — don't improvise from memory. This skill states only *what* each connection must do; the *how* lives in the connector skill. Connector flows are interactive → main session, never backgrounded.
- Every project repository is **PRIVATE**.
- All keys live in **`.env` only** (`chmod 600`), named per `claudeconnectorskillheadless/storingsecrets.md`, and recorded (name only, never the value) in the project's `CLAUDE.md`. Never write a key elsewhere, never commit `.env`, never echo a key back.
- **Least privilege:** scoped tokens, never global/unrestricted keys where a scoped one will do — and **per-project credentials**: never borrow another project's token.
- **No direct-upload projects:** every site is a private GitHub repo Git-connected to a Cloudflare Pages project; never create a direct-upload Pages project (can't convert later; would change the `*.pages.dev` URL).

## Step 0 — TRIAGE FIRST: new build or existing website?

**Before anything else, establish which situation you're in.** Ask if unclear from context:

> Are we building a brand-new website from scratch, or working on an existing one?

Then follow exactly one path below. **Do not start the new-build workflow until this is settled.**

### Path A — EXISTING website

The numbered workflow below is for **greenfield builds** — for an existing site, **STOP following it mechanically**. Understand what exists, then decide with the user how to proceed:

1. **Locate the site's home.** Local project (check `projects/README.md` and `projects/<name>/CLAUDE.md`)? GitHub repo? Both? Neither? Ask the user for what you can't find. **If `projects/<name>/CLAUDE.md` exists, read its `## Status` block first** (if present) — it's the fast-resume summary (Done / End-state plan / Immediate next steps / Suggest-ask-user-next / Decided against); everything below it in the file is historical/investigation detail, only worth digging into if the Status block references it or something needs deeper context. Don't re-derive state that's already answered there.
2. **If there's a GitHub repo — check access.** Look for a stored credential covering that repo (per `claudeconnectorskillheadless/githubconnect.md` §0 — grep `.env` for `GITHUB_PAT` vars) and verify it can actually read the repo (a live API read, not just the var existing). **If no access, connect it now:** follow `claudeconnectorskillheadless/connectorskill.md` → GitHub rows → `claudeconnectorskillheadless/githubconnect.md` §2 (fine-grained, single-repo PAT), interactively in the main session. Then clone the repo into the project folder.
3. **Analyze the codebase** (a discrete read-only task — a **background agent** is fine). Establish:
   - **Stack:** Astro? React islands? Something else (WordPress, Next.js, plain HTML, Wix export…)?
   - **Hosting/deploy:** Cloudflare Pages Git-connected? Direct-upload? Another host (Vercel, Netlify, cPanel…)? Is the site live, and at what URL(s)?
   - **This skill's fixtures:** CMS wired in (Tina Cloud by default; some legacy sites use Keystatic)? Activated? Access/Zero Trust preview gate? Turnstile? Business tools — CRM form handler, payments, scheduling? Custom domain attached?
4. **Decide: does it generally follow this skill's framework** (Astro + React islands, private GitHub repo, Git-connected Cloudflare Pages) **or is it something completely different?**
   - **Follows the framework →** work out **where in the lifecycle it actually is** by probing real state, not assuming (e.g. live but CMS never activated; built but no CRM; preview-gated but never launched; live but no custom domain). Map that onto the workflow to find the right re-entry point(s), then **present a short status summary + suggested next steps** (e.g. *"The site is live on Pages and CMS-ready, but Tina Cloud was never activated and there's no CRM. Suggest: 1) activate Tina Cloud, 2) connect HubSpot for the contact form, 3) set up your custom domain. Which first?"*) and proceed on their choice — using the workflow steps as reference, not a script. **Any content/code change follows the branch → preview → confirm → merge loop** (see "Editing an existing framework site") — never edit straight on `main`.
   - **Completely different →** do NOT force it into this framework or rebuild it unasked. Work out the best way forward for *that* stack, tell the user what you found and what you recommend — which may be "manage it as-is", "migrate to the standard stack", or in between — and let them decide. Only if they choose a rebuild/migration does the new-build workflow apply (with content ported over).
5. **Record findings** in the project's `CLAUDE.md` (stack, hosting, URLs, credential var names, current lifecycle position) so the next session doesn't re-derive them — see "Progress tracking" below for the required format.

### Path B — NEW build (from scratch)

**Before anything else, tell the user the plan:** first connect **Cloudflare** (hosting) and create a **private GitHub repo** (source of truth) — the mandatory foundation, set up **before any site code is written**. Something like:

> Great — before we design anything, I'll get the foundations in place: connect your Cloudflare account (where the site is hosted) and create a private GitHub repo (where the code lives). Then we'll move on to design and build.

Then run the new-build workflow below in order.

## Progress tracking — the project CLAUDE.md `## Status` block

Every site project (new or existing) keeps its state in `projects/<name>/CLAUDE.md` — but a growing narrative log gets expensive to re-read every session. **Require a fixed `## Status` block at the very top of the file** (right after the title, before anything else), with exactly these five subsections:

```
## Status (updated: <YYYY-MM-DD>)

### Done
- What's actually built/live/verified, most-recent first.

### End-state plan
- The agreed target shape of the finished site/business setup.

### Immediate next steps
- The concrete next actions — who does each (owner vs. assistant).

### Suggest / ask the user next
- What to proactively raise or propose next session (upsell-worthy
  gaps, decisions the user hasn't weighed in on yet, things worth
  flagging) — distinct from "Immediate next steps": those are already
  agreed-on actions, this is what still needs the user's input or
  might be worth surfacing even though nobody asked for it yet.

### Decided against
- Options that were considered and explicitly rejected, with why —
  so they don't get silently re-proposed in a later session.
```

Everything else in the file (detailed history, investigation notes, credential var names, sandbox quirks) stays below this block, unchanged — it's reference detail for when something needs digging into, not the first thing to read.

- **On resuming** (Path A step 1): read the Status block first, don't re-derive from the narrative unless the Status block points you there.
- **On any meaningful milestone or decision** (a feature shipped, a scope change, an option explicitly turned down): update the Status block — move items from "Immediate next steps" to "Done", add anything newly decided against, bump the `updated:` date. Don't just append a new narrative paragraph and leave Status stale.
- Applies retroactively too — if you touch a project whose `CLAUDE.md` predates this convention, add the Status block on your next edit rather than leaving it without one.

## Technology stack

- **Cloudflare** — hosts the whole app (Pages, Workers, D1, R2, Web Analytics, Access/Zero Trust, Turnstile, DNS). **CORE.**
- **Astro + React islands** — single frontend stack for all site types; SSR, middleware, protected routes. **CORE.**
- **GitHub** — private repo is the source of truth, Git-connected to Cloudflare Pages for auto-deploy. **MANDATORY.**
- **Tina Cloud (CMS)** — **default, recommended** so the owner can self-edit: content stays as Markdown in the repo, Tina Cloud hosts the editing backend. **Keystatic** (self-hosted, no third-party account) is the alternative. See step 14 + `tina-cloud-setup.md`.

> **VERIFY BEFORE INSTRUCTING.** Provider dashboards and permission/scope names drift. Before walking the user through any setup step, verify it against the provider's **latest official docs** (use `agent-browser --cdp 9222`, `WebFetch`, or `WebSearch`). Treat the steps below as a current-best guide.

## Workflow — new build, first stage (basic site)

> **⚠️ SET UP CLOUDFLARE + GITHUB BEFORE BUILDING THE SITE.** They're the mandatory foundation — provision them FIRST. Concretely: do intake/design (steps 2–5), then connect Cloudflare, create the PRIVATE GitHub repo + scoped token and the Git-connected Pages project (steps 6–11) **before** the build-and-deploy step (step 12). Don't hand-build a site and retrofit hosting — a direct-upload/local-first path can't be cleanly converted to Git-connected Pages later.
>
> **🚫 DO NOT SERVE OR PREVIEW THE SITE LOCALLY.** Never run a local dev/preview server (`astro dev`, `npm run dev`, `npm run preview`) and never take local headless-Chromium screenshots — slow and unreliable here. The ONLY preview is the deployed Cloudflare Pages URL. Verify a build with `npm run build` (compile check) and the live site with `curl -s -o /dev/null -w "%{http_code}" https://<project>.pages.dev` expecting `200`. Deploy-first review, always.

1. **Announce the plan** (Step 0 Path B): Cloudflare + GitHub repo first, then design and build.
2. **Intake.** Ask for a high-level description of the site they want.
3. **Create the project.** Create a project folder and tell the user the project name.
4. **Classify SME taxonomy.** Decide the site's conversion goal + transaction model. If unclear, ask. Types:
   - **T1 — Lead-gen / Marketing:** capture a lead (form/email/WhatsApp); no on-site transaction; needs form capture + spam protection + a notify path.
   - **T2 — E-commerce, physical goods:** sell a physical product; one-time payment; needs real inventory/stock management.
   - **T3 — E-commerce, digital / downloadable:** sell a downloadable (ebooks/files/templates); one-time payment; needs secure file delivery + global VAT handling. (Software/SaaS = recurring → T5.)
   - **T4 — Reservation / Appointment:** book a time slot (restaurant/spa/clinic/tutor/tour); may or may not take payment; needs slot booking + availability + reminders.
   - **T5 — Membership / Subscription:** recurring access (gyms/courses/communities/SaaS); recurring billing + gated access.
5. **Design-style intake.** Ask whether there's a particular visual style — described in words, an existing site, an uploaded/linked template, or a screenshot. Also ask what **content assets** the client can provide (logo, real copy, photos) versus what you should source (stock) or placeholder and flag — don't discover at build time that there's no content.

> **Essential infrastructure: Cloudflare (hosting) + GitHub (stores the code).** Both mandatory for every site.

6. **Connect Cloudflare — via the connector skill.**
   1. **FIRST, check for a credential matching THIS project** (per `claudeconnectorskillheadless/connectorskill.md` → "Before connecting"): look in `.env` for `<PROJECT>_CLOUDFLARE_API_TOKEN` / an equivalent per-project secret. If it exists and verifies live (active + reaches Pages/D1/R2/Access/DNS), reuse it and skip the rest. **Do NOT reuse another project's token.**
   2. Otherwise **follow `claudeconnectorskillheadless/connectorskill.md`** (its Cloudflare row / method resolution) to connect, interactively in the main session. Whatever method it resolves to, the credential must be able to manage, on the client's account: **Pages, Workers (+ KV, R2, D1), Access/Zero Trust (apps + org), DNS, Zone settings, SSL, Page Rules, Workers Routes, Turnstile, Email Routing (addresses + rules), Cache Purge** — Access: Apps and Policies Edit enables the preview-gating step. If the method is an API token (connector-skill method #3), request a **scoped custom token** with exactly those permission groups (never the Global API Key; build a pre-filled `dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=…` deep link per method #3 — verify current permission-group keys live via `GET /client/v4/user/tokens/permission_groups`).
   3. **Store + verify:** save in `.env` (`chmod 600`) named for THIS project per `claudeconnectorskillheadless/storingsecrets.md`, record the var name in the project `CLAUDE.md`, and verify it works (Access / Pages / D1 / R2 reachable).

7. **Gate the preview with Cloudflare Zero Trust (Access) — STANDARD.** While in preview, gate the site so only whitelisted people can view it. **Ask which email(s) get preview access** (owner at minimum). Create a **Cloudflare Access application** covering the Pages domain (`*.pages.dev` now, custom domain later) with an **Access policy allowing only those emails via one-time PIN (email OTP)**. Everyone else hits the Access login screen. (A one-time Zero Trust org/team-name `auth_domain` setup may be needed on first use.)
   - **⚠️ Do NOT gate the CMS admin route.** For Tina Cloud, exclude **`/admin`** — the editor authenticates against Tina Cloud and redirects back, so gating breaks the round-trip. (For a Keystatic site, exclude `/keystatic` and `/api/keystatic/*` instead.) Gate other admin areas if any, but always exclude the CMS admin route(s).
   - **At launch, REMOVE / disable the Access application** so the site becomes public.
   - *Fallback only:* if the credential lacks the Access permission, gate with HTTP Basic Auth via a Pages Functions `_middleware.js` (shared password). Zero Trust is the standard method.
   - **⚠️ Any webhook-receiving integration added LATER needs its endpoint path added as a Zero Trust `bypass` app.** A whole-domain Access gate intercepts *every* request before it reaches the site's code — including server-to-server webhooks (Clerk auth, Stripe payments, HubSpot workflows, Shopify e-commerce — anything that POSTs to a `/api/hooks/...` path). The external service gets redirected to the Access login and its delivery just fails/retries/gives up — **silently**, with no site crash to notice, so it's easy to miss. For each such path, add a narrow path-scoped `bypass` application (e.g. `<site>/api/hooks/clerk`, decision `bypass`, everyone) following the same Admin Bypass pattern above for CMS routes; verify with an unauthenticated `curl -I` that the path reaches the site (a `4xx` from the endpoint's own signature check), not a `*.cloudflareaccess.com` redirect. Safe because webhook endpoints verify a cryptographic signature themselves — see business-tools.md §6 "Watch out for".

8. **GitHub repo — MANDATORY, PRIVATE, created FIRST (before the token).** The repo is the source of truth: backup, optional CMS self-editing (step 14), and what Pages auto-deploys from. Create the repo BEFORE the token so the fine-grained PAT can be scoped to that exact repo. Recommend the user create the GitHub account with their existing Google email if they don't have one.
   - **Follow `claudeconnectorskillheadless/githubconnect.md` §1** (create a repo) — **run foreground**: reuse a stored repo-creating token if one exists, else deep-link the user to the creation page. Name it `<projectname>-website`, visibility **Private**.

9. **GitHub token, scoped to that repo.** **Follow `claudeconnectorskillheadless/connectorskill.md` → GitHub "work on a repo" row → `claudeconnectorskillheadless/githubconnect.md` §2** (fine-grained, single-repo PAT — including its validation and all-repos-scope detection steps) — **run foreground**. This skill needs, on the one `<projectname>-website` repo: **Administration write, Contents write** (push + Keystatic), **Workflows write, Pull requests write, Issues write** (Metadata read is automatic). Store per `claudeconnectorskillheadless/storingsecrets.md` / `claudeconnectorskillheadless/githubconnect.md` §Storing, record the var name in the project `CLAUDE.md`.

10. **Grant the Cloudflare GitHub App access to the new repo (REQUIRED before linking Pages).** Otherwise Cloudflare's Connect-to-Git / the Pages-project API shows "No repositories matching..." or fails with error 8000012. Send the user to the GitHub App's config: `https://github.com/settings/installations` → **"Cloudflare Workers and Pages"** → **Configure** → **Repository access** → **"All repositories"** (recommended) or add the new `<projectname>-website` repo → **Save**.
    - Each install also has an account-specific ID that deep-links straight to this config page (`.../settings/installations/<id>`); it's a handy shortcut once you know a given account's ID, but **never hardcode one** — the generic path above always works and is account-agnostic.

11. **Create a Git-connected Cloudflare Pages project (NOT direct-upload) — Claude does this via the Cloudflare API.**
    > **⚠️ A direct-upload Pages project CANNOT be converted to Git-connected later** — you'd need a new project, changing the `*.pages.dev` URL. Always create it Git-connected from the start.

    **PRIMARY — Claude creates it via the Cloudflare API** (works only after step 10 and while the GitHub↔Cloudflare OAuth is healthy):
    1. **Fetch repo IDs:** `GET https://api.github.com/repos/{owner}/{repo}` with the project's GitHub token → read `id` (= `repo_id`) and `owner.id` (= `owner_id`).
    2. **Create the project:** `POST https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/pages/projects` with the project's Cloudflare token (resolve `<ACCOUNT_ID>` via `GET https://api.cloudflare.com/client/v4/accounts` — never hardcode). Body:
       ```json
       {
         "name": "<projectname>-website",
         "production_branch": "main",
         "source": {
           "type": "github",
           "config": {
             "owner": "<github-owner>",
             "repo_name": "<projectname>-website",
             "repo_id": "<repo_id>",
             "owner_id": "<owner_id>",
             "production_branch": "main",
             "pr_comments_enabled": true,
             "deployments_enabled": true,
             "production_deployments_enabled": true,
             "preview_deployment_setting": "all",
             "preview_branch_includes": ["*"],
             "preview_branch_excludes": ["main"]
           }
         },
         "build_config": {
           "build_command": "npm run build",
           "destination_dir": "dist",
           "root_dir": ""
         }
       }
       ```
       `root_dir` blank unless the app is in a subdirectory; `destination_dir` is `dist` for Astro; `build_command` is `npm run build`. If unsure of the shape, mirror an existing working project via `GET .../pages/projects/<existing-name>`.
    3. **No CMS env vars are needed at project-create time.** Tina Cloud (step 14) needs its 2 env vars only once the owner activates it (14b), after the Tina Cloud project exists. (A Keystatic site provisions its bootstrap env vars at activation, also not here.)
    4. **Trigger/confirm deploy:** a Git-connected project auto-deploys on push to `main`; if it doesn't, `POST https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/pages/projects/<projectname>-website/deployments`.

    **FALLBACK — dashboard Connect-to-Git (ONLY if the API returns error 8000012,** meaning the GitHub↔Cloudflare OAuth is stale): deep link `https://dash.cloudflare.com/?to=/:account/workers-and-pages/create/pages` (if it 404s, `https://dash.cloudflare.com/?to=/:account/workers-and-pages` → Create application → Pages → Connect to Git). Select the repo; set Production branch `main`, Framework preset Astro, Build command `npm run build`, Build output `dist`, Root blank → Save and Deploy. The **GitHub OAuth approval** inside this flow must be clicked by the owner — it refreshes the stale connection, after which the API path works again.

12. **Build & deploy — the discrete task that runs as a BACKGROUND agent.** **⚠️ Read `tina-cloud-setup.md` in full BEFORE any `npm install`/`npm create astro`** — its native-compile callout must be known before the first install, not after one fails. Build the site (Astro + React islands, mobile-friendly), push to GitHub, let the Git-connected Pages project auto-deploy. **Build the site CMS-ready by default** — wire in Tina Cloud per `tina-cloud-setup.md` §14a so self-editing can be offered later with zero rebuild (adds no secrets, activates nothing). **Verify** per the no-local-preview rule above: `curl` the deployed `*.pages.dev` URL expecting `200`; a live-URL screenshot is optional best-effort.
    - **⚠️ ADAPTER GOTCHA — `@astrojs/cloudflare` v13 breaks Pages (404 at root).** The v13 adapter emits the **Workers + Static Assets** layout (`dist/client/`, `dist/server/entry.mjs`, `dist/server/wrangler.json`), which a Cloudflare **Pages** project cannot serve → every route 404s. For a **Pages** deploy, use the **v12 line** (`@astrojs/cloudflare@^12`), which emits Pages-native output: `dist/_worker.js/` + client assets (`_astro/`, `_routes.json`) at the `dist/` root. v12 peers: `astro@^5`, `@astrojs/react@^4` (React 19 is fine). After `npm run build`, **confirm `dist/_worker.js` exists and there is NO `dist/server/wrangler.json`** before trusting the deploy. (Verify against current docs — may change.)
    - **⚠️ Verifying behind the Access gate (step 7):** once gated, the canonical `https://<project>.pages.dev` returns **302** to the Access login, not 200 — so curl the **un-gated per-deployment hash URL** `https://<hash>.<project>.pages.dev/` (expect `200` + real HTML, e.g. the `<title>`) to confirm the site renders, and treat the canonical 302 as proof the gate is intact.
    - **Baseline content + SEO, not just a layout.** Ship real copy/images per the step-5 assets answer — never leave lorem ipsum on a live URL. Every build includes a favicon, per-page `<title>` + meta description, Open Graph tags, and a generated `sitemap.xml` + `robots.txt`; wire in **Cloudflare Web Analytics** (business-tools.md §7) so traffic is measured from launch, not bolted on later.

13. **Confirm the preview gate.** Ensure the step 7 Access gate is active on the deployed URL (and custom domain once attached), only whitelisted emails can log in, and the CMS admin route is still excluded (routes in step 7). Remind the user the gate is removed at launch.

14. **CMS (Tina Cloud) — WIRE IN BY DEFAULT during the build (§14a, part of step 12 — adds no secrets, activates nothing); ACTIVATION (§14b) is RECOMMENDED — offer once the preview URL is live:** connecting the repo to a Tina Cloud project lets the owner self-edit, but don't force it — they may be happy to just tell the assistant what to change. **Follow `tina-cloud-setup.md` for all CMS wiring.** **Keystatic** (self-hosted alternative, only when the owner wants no third-party account): `keystatic-appendix.md`.

15. **Send links.** Send the Cloudflare Pages link (and the CMS `/admin` link if Tina Cloud is set up).
16. **Legal / privacy pages — REQUIRED before a public launch for any site that collects personal data** (lead/contact forms, analytics, membership — essentially all of them). Add at minimum a **privacy policy** and a **cookie/consent notice**, plus terms of service if the site transacts (T2/T3/T5). This is a real compliance obligation (GDPR in the EU/UK, CCPA in California, PDPA in parts of Asia — whichever applies to the client's jurisdiction), not optional polish — a public form capturing emails with no privacy policy is a liability. Generate baseline pages from the client's actual data practices (what's collected, which processors — HubSpot / Stripe / Clerk / Resend / Cloudflare — and retention), link them in the footer, and have the client review. Flag clearly that this is scaffolding to review, **not legal advice**.
17. **Domain setup.** Ask if they have a domain. If their registrar is not Cloudflare, give instructions to point it to Cloudflare (nameservers/DNS). If none, offer to register one via Cloudflare — a paid purchase on **the client's own account with the client's card**; per the financial guardrail you set up the rails but the owner completes any real-money step (browser-intervention hand-off), never your own payment details.
18. **Final handoff.** After the domain is live, send the final domain name (and the CMS `/admin` link if set up).

## Editing an existing framework site — branch → preview → confirm → PR → merge

For **any content/code change to a site that follows this framework** (built by this skill or inherited via Path A), never edit `main` directly — `main` IS production (the Git-connected Pages project auto-deploys it), and the global git rule forbids direct pushes to master/main. Instead:

1. **Create a feature branch** in the site repo (e.g. `edit-<short-description>`), make the changes there, and push. The change work itself is a discrete task — a **background agent** is fine; the user-facing loop stays in the main session.
2. **Cloudflare auto-builds a preview.** *(Verified against Cloudflare docs, 2026-07: every push to a non-production branch triggers a preview deployment; the step 11 config enables this.)* Each push produces **two preview URLs**:
   - a **per-commit URL** — `https://<hash>.<project>.pages.dev` (unique per deployment), and
   - a **stable branch alias** — `https://<branch-alias>.<project>.pages.dev` (branch name lowercased/DNS-sanitized — non-alphanumerics become hyphens, very long names truncated + hashed; the alias stays the same across commits and always shows the latest).
   Confirm the preview build succeeded before sending anything: `GET .../pages/projects/<name>/deployments` (filter `env=preview`, match the branch/commit) and `curl -s -o /dev/null -w "%{http_code}"` the preview URL expecting `200`. If it failed, read the deployment logs, fix on the branch, push again.
3. **Send the preview link** (prefer the stable branch alias — it survives follow-up pushes) with a one-line summary of what changed, and **ask them to confirm**. Two caveats:
   - **Preview deployments use the project's `preview` env vars** — which is why this skill sets secrets on BOTH `production` and `preview` (steps 11/14b, Part 2). If a change involves a new secret, set it on both before judging the preview.
   - **An Access gate covering only the canonical `<project>.pages.dev` does NOT cover preview subdomains** — handy (the user can open the preview without an OTP), but flag it if the change is confidential and add the preview hostnames to the Access app if needed.
4. **Iterate on the same branch** until the user is happy — each push refreshes the same branch-alias preview link.
5. **On the user's explicit OK — and only then — open a PR** from the branch to `main` (Pages also comments the preview URLs on the PR automatically, `pr_comments_enabled` is on) **and merge it.** The merge to `main` auto-deploys production. Verify live: curl the canonical URL / custom domain (expect `200`, or `302` if still preview-gated — then check the per-deployment hash URL) and confirm the change is visible. Delete the feature branch after merge.
6. **No OK, no merge.** If the user rejects the change or goes quiet, the branch just sits there — production is untouched. Never merge on silence.

## Part 2 — Connecting business tools to the site

Once the basic site is up (or when resuming a site that lacks them), connect business tools per **`business-tools.md`** — CRM (HubSpot: exact scopes, form handler, Turnstile), payments (Stripe), e-commerce (Shopify), scheduling, and everything else. Shortlist from the SME taxonomy (step 4), confirmed with the user; connect only what serves an agreed need.
