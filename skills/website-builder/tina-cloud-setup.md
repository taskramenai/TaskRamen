# Tina Cloud CMS — setup & activation

The default, recommended CMS for sites built with this skill (see `SKILL.md` step 14). Content stays as Markdown/MDX/JSON in the repo (single source of truth); Tina Cloud hosts the editing backend (GraphQL indexing + editor auth), so **nothing CMS-related runs on Cloudflare Workers** — `/admin` is plain static files, no serverless callback, no database. Edits in `/admin` commit back to the repo and auto-redeploy.

**Why the default:** self-hosting Tina's GraphQL/index/auth backend on Workers is off the beaten path (Tina's starters target Vercel/Netlify + a database adapter; the fully-Cloudflare example is a proof-of-concept) — Tina Cloud removes all of that: static site on Cloudflare as before, backend handed to Tina Cloud (free tier for small sites). **Keystatic** (fully self-hosted, no third-party account) is the alternative — see `keystatic-appendix.md`.

> **VERIFY BEFORE INSTRUCTING.** Tina Cloud dashboard labels and flows drift — verify UI paths against app.tina.io live at setup time.

> **⚠️ READ THIS BEFORE YOU RUN `npm install` (sandbox environments without a C toolchain).** `@tinacms/cli` pulls in `better-sqlite3`, a **native module that needs to compile C++ code** (via `node-gyp`/`make`) — most sandboxes have no `gcc`/`make`/root, so that compile step fails.
> - **DO NOT** try to install `build-essential`/`gcc`/`make` (usually no `sudo`) or hunt for a prebuilt binary.
> - **DO NOT** drop Tina Cloud to work around it — this is fully avoidable and Tina stays the default.
> - **DO** run `npm install --ignore-scripts` instead — from the **first** install onward, before you get anywhere near Tina-specific config. It skips ALL native postinstall/build steps for every package; the local-search feature `better-sqlite3` powers isn't needed for a static Astro build, so nothing is lost. (Other sandbox quirks — cache dirs, git identity, telemetry — are in 14a.)

## 14a — DEFAULT (build-time, always done as part of the step-12 build)

Make every site Tina-ready out of the box so activation later is frictionless. **This adds NO secrets and activates nothing.**

- Model editable content (text, prices, images) as **Markdown/MDX/JSON files in the repo** (e.g. `src/content/…`). Astro pages READ that content via **Astro content collections / a local file read — NOT via the Tina Cloud client** — so the public build has **zero runtime dependency on Tina Cloud** and always renders. Keep it the single source of truth that also feeds things like form selects; don't hardcode copy/prices in components.
- Add `tinacms` + `@tinacms/cli` and a **`tina/config.ts`** describing that same content as Tina collections/singletons (fields point at the same files). Real, verified-working template (from a live site build, 2026-07-04 — adapt collection names/fields, keep the `clientId`/`token` handling exactly as-is):
  ```ts
  import { defineConfig } from "tinacms";

  // ⚠️ Do NOT use a literal `null` for clientId/token: @tinacms/cli's
  // non-local `build` throws "Client not configured properly" on a falsy
  // clientId/token/branch, checked BEFORE --skip-cloud-checks is evaluated
  // (verified in @tinacms/cli 1.8.0 and 1.12.6). Use a non-empty placeholder
  // sentinel — it satisfies the check without connecting anything real.
  const NOT_ACTIVATED = "tina-cloud-not-yet-activated";

  export default defineConfig({
    branch:   process.env.CF_PAGES_BRANCH || "main", // Cloudflare Pages exposes the deploy branch here
    clientId: process.env.PUBLIC_TINA_CLIENT_ID || NOT_ACTIVATED, // real value set at activation (14b)
    token:    process.env.TINA_TOKEN || NOT_ACTIVATED,            // read-only Content token, set at activation
    build:  { outputFolder: "admin", publicFolder: "public" }, // static admin SPA → /admin
    media:  { tina: { mediaRoot: "images", publicFolder: "public" } },
    schema: {
      collections: [
        {
          name: "services",              // ← rename/duplicate per site; this shape fits any
          label: "Services",              //   repeating priced item (services/products/menu/etc.)
          path: "src/content/services",
          format: "md",
          fields: [
            { type: "string", name: "name", label: "Name", isTitle: true, required: true },
            { type: "string", name: "category", label: "Category", options: ["massage", "facial"], required: true },
            { type: "string", name: "duration", label: "Duration", required: true },
            { type: "string", name: "price", label: "Price", required: true },
            { type: "number", name: "order", label: "Display order" },
            { type: "string", name: "description", label: "Short description", ui: { component: "textarea" }, required: true },
            { type: "rich-text", name: "body", label: "Extra notes (optional)", isBody: true },
          ],
        },
        {
          name: "about",                 // ← a singleton-style page: one file, one document
          label: "About Page",
          path: "src/content/about",
          format: "md",
          fields: [
            { type: "string", name: "title", label: "Title", isTitle: true, required: true },
            { type: "string", name: "intro", label: "Intro paragraph", ui: { component: "textarea" }, required: true },
            { type: "rich-text", name: "body", label: "Body", isBody: true },
          ],
        },
        {
          name: "contactInfo",           // ← JSON format works too, not just Markdown
          label: "Contact Info",
          path: "src/content/contactInfo",
          format: "json",
          fields: [
            { type: "string", name: "phone", label: "Phone", required: true },
            { type: "string", name: "email", label: "Email", required: true },
            { type: "string", name: "address", label: "Address", required: true },
            { type: "object", name: "hours", label: "Hours", list: true, fields: [
              { type: "string", name: "day", label: "Day(s)" },
              { type: "string", name: "hours", label: "Hours" },
            ] },
          ],
        },
        // ⚠️ Every field referenced by content files must be declared here — an
        // undefined key in a content file (e.g. a stray "_comment") can trip
        // schema validation on a fresh Tina Cloud reindex.
      ],
    },
  })
  ```
- Set the package.json `build` script to **`tinacms build --skip-cloud-checks && astro build`** so the static admin generates into `public/admin` alongside the site. The Cloudflare Pages `build_command` stays `npm run build` (SKILL.md step 11) — it now transitively runs `tinacms build`. **Commit the generated `tina/tina-lock.json`** — Tina Cloud needs it to index content.
- **⚠️ Keep `--skip-cloud-checks` permanently.** Without it a non-`--local` `tinacms build` phones Tina Cloud to validate the client/schema — which fails pre-activation (the placeholder sentinel isn't a real project), so every build would fail before 14b. The flag only skips that build-time call; it does NOT disable the deployed admin, which still uses `clientId`/`token` at runtime once activated — so the same script works before AND after activation. Do NOT use `--local` (that switches to a local content server, for `tinacms dev`, not a production build).
- With `clientId`/`token` still at the `NOT_ACTIVATED` placeholder (no Tina Cloud project yet), the build passes and the public site renders identically from the committed Markdown; `/admin` loads but can't authenticate until 14b. Keep the v12 adapter pin from SKILL.md step 12 — the Tina admin is static files, so it adds no serverless routes.
- **⚠️ Other sandbox quirks** (native-compile avoidance is the callout at the top of this file — see that first): `~/.cache`/`~/.config` are often root-owned/unwritable in these sandboxes, so set `XDG_CACHE_HOME`/`XDG_CONFIG_HOME` to a writable scratch dir and `ASTRO_TELEMETRY_DISABLED=1` before `npm install`/`npm run build`; and set git `user.name`/`user.email` **locally** in the repo (not `--global`) before the first commit.
- **⚠️ Access gate (SKILL.md step 7): EXCLUDE `/admin`** — gating it breaks the Tina Cloud auth round-trip. No other CMS routes exist.

## 14b — ACTIVATION (RECOMMENDED — offer once the preview URL is live)

Turns the already-wired-in CMS on by connecting the repo to a Tina Cloud project. Present it as the recommended way for the owner to self-edit; don't force it.

**Owner walkthrough — no deep links exist** (Tina Cloud uses opaque per-project IDs, confirmed 2026-07-04; don't guess a URL or ask the owner to fish one from their address bar). This is an interactive service-connection flow → **run foreground**. **Send these one at a time, waiting for each reply — same as any connector step:**
  1. *"Open **app.tina.io** and sign in."*
  2. *"Click **New project**, connect your GitHub account if asked, then select the **`<projectname>-website`** repo and set the base branch to **main**."* (A GitHub-App authorization — must be the owner, in their own browser.)
  3. *"On the project setup page, find **Site URL(s)** (defaults to `http://localhost:3000`) and replace it with your site's actual address: **`https://<projectname>-website.pages.dev`** — just that, no path after it. Then click Create Project."*
  4. *"You'll see a checklist after that — ignore it, I'll tell you what actually matters."* (Internally: the checklist's "Set up your site schema" step suggests `npx @tinacms/cli@latest init && npx tinacms dev` — **never relay this**, `init` would scaffold a generic schema over the custom one from 14a.)
  5. *"Go to the project's **Overview** tab and copy the **Client ID**, then go to the **Tokens** tab, create a **Read-only Content token**, and copy that too. Send me both."*
  6. Once you have both: Claude sets them as Pages env vars and redeploys — technical detail below.
  7. **Always do this next, proactively — do NOT wait for a login error.** A newly-connected project reliably fails to index a branch that already existed before Tina Cloud was connected (the normal case here — the repo is created in step 8, long before this). So walk the owner through the reindex now, before the first login attempt, one message at a time: *"In the Tina Cloud dashboard, click **Configuration** in the left sidebar."* → *"Click **Refresh branches** — `main` won't show up in the branch list until you do this."* → *"Next to **main**, click the three-dot (⋮) menu and choose **Reindex**."* → *"Give it a minute."* (Exact UI path verified 2026-07-04: **Configuration → Refresh branches → ⋮ menu → Reindex** — Reindex is inside the ⋮ menu, not a standalone button.)
  8. Now have them log in: *"Open **`<site-url>/admin`**, log in via GitHub, and try editing something. Save commits straight to your repo and the site redeploys automatically."*
  9. **Fallback if step 8 still shows "Index version 0 no longer supported. Reindex your project"** (rare once step 7 is done first, but possible): repeat step 7 once more. If `main` still doesn't appear after refreshing, or Reindex still errors, it's a platform-side stuck state — tell the owner to email **support@tina.io** with the Client ID, branch (`main`), and the exact error, asking for a server-side index reset.

**Technical detail for step 6 (Claude does this, not the owner):**
- **Set the two values as Pages env vars (BOTH `production` and `preview` — GET then MERGE `deployment_configs` so you don't clobber other settings):** `PUBLIC_TINA_CLIENT_ID` (`plain_text`, the Client ID — public, baked into the admin SPA) and `TINA_TOKEN` (`secret_text`, the read-only Content token).
  ```json
  "deployment_configs": {
    "production": { "env_vars": {
      "PUBLIC_TINA_CLIENT_ID": { "type": "plain_text",  "value": "<client-id>" },
      "TINA_TOKEN":            { "type": "secret_text", "value": "<read-only-content-token>" }
    } },
    "preview": { "env_vars": {
      "PUBLIC_TINA_CLIENT_ID": { "type": "plain_text",  "value": "<client-id>" },
      "TINA_TOKEN":            { "type": "secret_text", "value": "<read-only-content-token>" }
    } }
  }
  ```
- **Ensure `tina/tina-lock.json` is committed and pushed** (14a already builds it) — Tina Cloud indexes from it — then **redeploy** (`POST .../pages/projects/{name}/deployments`).
- **Owner experience:** open `/admin` → log in via Tina Cloud (GitHub) → edit → **Save** commits to the repo → Pages auto-redeploys. No embedded Cloudflare token, no self-config callback route, no redeploy race — the backend lives in Tina Cloud, not on Workers.

**Notes:**
- **⚠️ "Index version 0" diagnostics (observed on a live site build, 2026-07-04).** The pre-existing-branch case (step 7's premise) can stick at index "version 0" even after a successful build + the standard whitespace-push-to-`tina-lock.json` trick (that only *re*indexes an already-valid index; it can't bootstrap one stuck at version 0). Telltale that it's this and not a schema/content bug: the project's **Event Log stays empty** (indexing never ran). Don't debug `tina/config.ts`/content first — go straight to Reindex (step 7).
- **No management API exists for Tina Cloud administration.** The only public API is the per-project **GraphQL content API** (read/write content once set up). Creating a project, minting the Client ID/Content token, and reindexing a branch are **dashboard-only** — don't look for a way to script 14b or the reindex fix; they require the owner's logged-in browser session.
- **Editors without a GitHub account:** in the dashboard, **User Management** → invite by email → add as a **Collaborator** → they log into `/admin` directly with email/password (Tina Cloud commits their edits to GitHub behind the scenes). Mention this if the owner wants to give non-technical staff editing access.
- **⚠️ SECURITY / scope:** `TINA_TOKEN` is a **read-only Content token** — safe for the public site's runtime. Editor *write* access is mediated by Tina Cloud auth (GitHub), NOT by any token on the site. Keep the Client ID public and the token as `secret_text`; never deploy a Tina Cloud *admin* credential to the site.
- **Content-safety (reassure the owner):** nothing of value lives only in Tina Cloud — content, schema (`tina/config.ts`) and the `/admin` editor all live in the repo; Tina Cloud is just a hosted index + auth broker. Deleting the Tina Cloud project leaves the site and content fully intact.
