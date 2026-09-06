# Appendix — Keystatic (alternative self-hosted CMS)

**Tina Cloud (`tina-cloud-setup.md`) is the default CMS.** Use Keystatic **only** when the owner specifically wants a **fully self-hosted CMS with no third-party account** — pure GitHub OAuth, everything on their own Cloudflare Pages project — and accepts the heavier wiring (a serverless self-config callback route, a redeploy-race mitigation, and an embedded Pages-scoped Cloudflare token). Content-safety is identical to Tina Cloud (both are Git-backed Markdown). Mirror the same build-time-wire-in / offer-activation shape as SKILL.md step 14.

## A. DEFAULT (build-time — wire in as part of the step-12 build)

Make the site CMS-ready out of the box so activation later is frictionless. Adds NO secrets and activates nothing — the editor just can't be logged into until step B; the build passes and the public site renders identically.
- Model editable content as Keystatic singletons/collections; Astro pages READ content via `@keystatic/core/reader` (don't hardcode copy/prices). Single source of truth that also feeds things like form selects.
- Add the `@keystatic/astro` integration + `keystatic.config.ts` (GitHub storage pointed at the project repo) and expose the `/keystatic` route.
- Ship the two custom template files that make the GitHub connection a one-tap flow on Cloudflare Pages (Workers runtime has no writable disk, so Keystatic's default local-dev route 500s):
  - `src/pages/keystatic/setup.astro` — overrides Keystatic's multi-field setup with a single **Create** button (route: `/keystatic/setup`).
  - `src/pages/api/keystatic/github/created-app.ts` — a serverless-safe custom callback route that self-configures the CMS (a concrete file beats Keystatic's injected catch-all in Astro's router). Reads runtime env from `locals.runtime.env` (@astrojs/cloudflare adapter, NOT `import.meta.env`).
- If the build is a Pages build, keep the v12 adapter pin from SKILL.md step 12 — pick Keystatic versions compatible with Astro 5.
- **⚠️ When gating the preview (SKILL.md step 7), EXCLUDE the Keystatic routes** (`/keystatic` and `/api/keystatic/*`) from the Access app, or the GitHub OAuth callback breaks.

## B. ACTIVATION (offer once the preview URL is live; only if the owner wants self-editing)

- **Bootstrap env vars the callback route needs (set on the Pages project, BOTH `production` and `preview` — GET then MERGE `deployment_configs` so you don't clobber other settings):**
  - `CF_API_TOKEN` — `secret_text` — a Cloudflare token scoped to **Pages:Edit only** (dedicated, narrow — NOT the broad build token; have the owner create it per `claudeconnectorskillheadless/connectorskill.md` method #3 practices — run foreground, one step at a time, tap-to-copy links).
  - `CF_ACCOUNT_ID` — `plain_text`.
  - `CF_PROJECT_NAME` — `plain_text` — `<projectname>-website`.
  ```json
  "deployment_configs": {
    "production": { "env_vars": {
      "CF_API_TOKEN":    { "type": "secret_text", "value": "<pages-edit-token>" },
      "CF_ACCOUNT_ID":   { "type": "plain_text",  "value": "<ACCOUNT_ID>" },
      "CF_PROJECT_NAME": { "type": "plain_text",  "value": "<projectname>-website" }
    } },
    "preview": { "env_vars": {
      "CF_API_TOKEN":    { "type": "secret_text", "value": "<pages-edit-token>" },
      "CF_ACCOUNT_ID":   { "type": "plain_text",  "value": "<ACCOUNT_ID>" },
      "CF_PROJECT_NAME": { "type": "plain_text",  "value": "<projectname>-website" }
    } }
  }
  ```
- **Self-config flow** (the route does this automatically): exchange the one-time `?code=` at `POST https://api.github.com/app-manifests/{code}/conversions` (REQUIRES a `User-Agent` header — GitHub returns 403 without one; code expires within ~1 min) → returns `client_id`, `client_secret`, `slug` → generate `KEYSTATIC_SECRET` (32 random bytes hex) → write the **4 runtime env vars** `KEYSTATIC_GITHUB_CLIENT_ID`, `KEYSTATIC_GITHUB_CLIENT_SECRET`, `KEYSTATIC_SECRET`, and `PUBLIC_KEYSTATIC_GITHUB_APP_SLUG` (= the `slug`) to the project's `deployment_configs` (prod + preview, GET-then-MERGE) via the CF API → redeploy (`POST .../pages/projects/{name}/deployments`). The route renders the install link.
- **The one manual tap — install the GitHub App on the repo** (cannot be automated; GitHub permission boundary): the route's success page hands the owner `https://github.com/apps/<app-slug>/installations/new` → select the repo (or All repositories) → **Install & Authorize**.
- **⚠️ REDEPLOY RACE — root cause + REQUIRED mitigation.** The 4 `KEYSTATIC_*` env vars the **Create** step writes only go LIVE after the redeploy it triggers finishes (~1–2 min). If the owner taps **Install & Authorize** before that, the GitHub OAuth callback runs against a deployment with no secrets and **errors** — and the OAuth `code` is **single-use**, so they're stuck. **Mitigation (mandatory):** the created-app success page MUST gate the **Install GitHub App** button behind a readiness poll, not a blind countdown:
    - Ship a `src/pages/api/keystatic/health.ts` endpoint (`prerender = false`, `Cache-Control: no-store`, always HTTP 200) returning `{ "ready": <boolean> }` where `ready = Boolean(locals.runtime.env.KEYSTATIC_GITHUB_CLIENT_ID && locals.runtime.env.KEYSTATIC_SECRET)` (runtime env via `locals.runtime.env`, NOT `import.meta.env`). It lives under `/api/keystatic`, already excluded from the Access gate.
    - The success page renders a waiting state ("⏳ Finishing setup… 1–2 minutes" + spinner + elapsed counter) with the Install button **hidden**; inline JS polls `GET /api/keystatic/health` every 3s. Only when the NEW live deployment reports `ready:true` does it reveal the Install button. Poll indefinitely; treat fetch errors as not-ready and keep retrying; after ~3 min show a gentle "still finishing… wait or refresh" note but keep polling. Result: no error page, no blind countdown.
- **Owner experience:** open `/keystatic/setup` → tap **Create** → approve "Create GitHub App" → success page shows "Finishing setup…" and **auto-waits for the redeploy** → when ready it reveals **Install on your repo** → **Install & Authorize** → log in at `/keystatic`.
- **⚠️ SECURITY:** the embedded `CF_API_TOKEN` MUST be scoped to **Pages:Edit only** (never a global/broad token) — it lives in the site's runtime env and only manages the owner's own Pages project.
- **FALLBACK** (if the route fails): exchange the single-use code by hand at `POST https://api.github.com/app-manifests/<code>/conversions` (with `User-Agent`), then set the same 4 runtime env vars (including `PUBLIC_KEYSTATIC_GITHUB_APP_SLUG`) on the Pages project via the CF API and redeploy.
- **Implementation note:** write `created-app.ts` and `health.ts` from the spec above (manifest exchange with `User-Agent`, env-var write via GET-then-MERGE, redeploy, and the mandatory readiness-poll gate on the Install button). If an earlier project in `projects/*/` already contains a working, readiness-gated copy of these two routes, reuse it verbatim — but never ship or reference project-specific values.
