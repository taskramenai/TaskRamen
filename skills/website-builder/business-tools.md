# Part 2 — Connecting business tools to the site

> **LAST_UPDATED: 2026-07-10**

**Purpose.** Once the basic site is up (or when resuming an existing site that lacks them), **review which business tools fit the client's needs and the type of website**, then connect the agreed ones and wire them in. Don't default to a fixed list: derive the shortlist from the **SME taxonomy** (SKILL.md step 4), confirm it with the user, and connect only what serves an agreed need.

**Ground rules for every tool here:**
- **Connections go through `claudeconnectorskillheadless/connectorskill.md`** (and its per-service runbooks), **run foreground** (interactive, main session, not backgrounded — SKILL.md operational rule; every "run foreground" below means this) — never hard-code a flow. **Prioritize services with an easy path** in its per-service table (claude.ai-connector rows first, then simple API key, then OAuth) — a tool marginally better on features but painful to connect is usually the wrong pick for an SME.
- **Two credential planes per service.** (a) **Builder access** — to administer the tool for the client: prefer the claude.ai connector / MCP tools; check whether the service's MCP tools are already live in the session before running any flow; any minted admin-scope token is **local-only** `.env` (`chmod 600`, per `claudeconnectorskillheadless/storingsecrets.md`), NEVER deployed. (b) **Site-runtime credentials** — what the deployed site calls the service with: always a **minimal-scope static key** stored as a Cloudflare Pages env var (`secret_text`, prod + preview), never in git; assume it can leak and scope accordingly.
- **No one-size wiring — think it through with the user.** For each service, work out the right connection to the website: an **embedded widget** (their JS on your page), a **hosted/redirect page** (send the visitor to the provider), or **server-side API calls** from the site's Astro endpoints. Weigh security/PCI (prefer provider-hosted surfaces so sensitive data never touches the site), blast radius of the runtime key, upkeep, and visitor UX. Present the recommendation + trade-off before wiring.
- **Verify live** — provider offerings, connector availability, and scope names drift; check `claudeconnectorskillheadless/connectorskill.md`'s table and the provider's docs at setup time.
- **Surface ongoing cost BEFORE connecting.** Most tools here are paid or freemium (HubSpot tiers, Stripe per-transaction fees, Shopify, Clerk, Resend, Tina Cloud). Before wiring anything with a recurring or usage-based cost, tell the client what it will run — the free-tier limits and exactly what tips into paid — so they choose knowingly. Never connect a billable service silently.

**Taxonomy → typical toolset (starting point, not a script):**

| Site type | Usually needs |
|---|---|
| **T1 Lead-gen** | CRM (forms → contacts/deals) + Turnstile; scheduling if consult-based |
| **T2 E-commerce, physical** | Shopify (inventory + checkout) + CRM; email marketing later |
| **T3 E-commerce, digital** | Stripe (checkout + Tax for VAT) + secure delivery (R2 signed URLs) + CRM |
| **T4 Reservation / appointment** | Scheduling tool (or custom booking) + CRM; Stripe if deposits/prepayment |
| **T5 Membership / subscription** | Stripe Billing (recurring) + gated access + CRM |

**Taxonomy → recommended deal pipeline stages** (design the FULL pipeline up front, not just an entry stage — see "Wire the form handler" below for how to check/create these):

| Site type | Suggested stages (entry → … → terminal) |
|---|---|
| **T1 Lead-gen** | New Enquiry → Contacted → Qualified → Won / Lost |
| **T2/T3 E-commerce** | Deal pipeline is usually **not needed** — Shopify/Stripe track the actual sale; only add one if the site also captures pre-purchase leads (e.g. wholesale/bulk enquiries), in which case use the T1 shape |
| **T4 Reservation / appointment** | Appointment Requested → Confirmed → Completed → Cancelled / No-show |
| **T5 Membership / subscription** | Trial Requested → Active → Churned / Cancelled |

## 1. CRM — most businesses need one. Recommend HubSpot.

The site's lead/reservation form auto-creates a **Contact** + a **Deal**, and the builder manages the client's CRM via the API. Two distinct requirements — resolve each via the connector skill, don't hard-code:

1. **Administer HubSpot (builder access — contacts, deals, pipelines, properties).** Follow **`claudeconnectorskillheadless/connectorskill.md`** (its HubSpot row — currently the claude.ai connector, R+W) — **run foreground**. Check first whether HubSpot MCP tools are already live in the session. If the connector route can't serve a task, fall back through `claudeconnectorskillheadless/connectorskill.md`'s method order (an admin-scope static token, if minted, is **local-only** `.env`, `chmod 600` — NEVER deployed).
2. **Link website forms to HubSpot (site runtime token).** No claude.ai connector provides this — it must be a **static token minted in the client's HubSpot account**, with **exactly these 3 scopes and no more**: `crm.objects.contacts.read`, `crm.objects.contacts.write`, `crm.objects.deals.write` (NOT `deals.read` — the form only creates deals). Acquire per `claudeconnectorskillheadless/connectorskill.md` (run foreground, one step at a time, tap-to-copy links; verify against the **latest HubSpot docs** — private-app mechanics drift). Store as a **Cloudflare Pages env var** `<PROJECT>_HUBSPOT_TOKEN` (`secret_text`, prod + preview) — never in git.

> **Scope gotchas (learned the hard way — still verify live):**
> - Products/catalog work needs `crm.objects.products.read` + `.write` (FREE-tier). **Do NOT use the legacy `e-commerce` scope** — it only grants on Professional/Enterprise, so it fails on free accounts.
> - Custom **fields** (properties) on line items/products/quotes are covered by the shared `crm.schemas.{contacts,companies,deals,quotes}.write` OR-list — **there is NO `crm.schemas.line_items.write` and NO `crm.schemas.products.*` scope**; don't request them (they don't exist and the deploy fails).
> - Custom **objects** (`crm.objects.custom.*` / `crm.schemas.custom.*`) need **Enterprise** — exclude, along with other paid-only scopes (`automation`, `content`, `hubdb`, `*.sensitive.*`, `crm.objects.leads.*`) that fail on a free account.
> - If a static token may need scopes added later: **include the full needed set at the FIRST deploy** — adding a scope later means redeploying the app and a repeat client round-trip.
> - Keep any admin credential and the SITE token separate: line-item/product/catalog enrichment uses builder/admin access, **never** by widening the public SITE token beyond its 3 scopes.

**Design the pipeline BEFORE wiring the form — don't just check for one entry stage.** Using your own builder/admin access (the HubSpot MCP connector, or `get_properties`/`search_properties` on the `dealstage` property — the SITE token can't do this, see below), read the account's existing pipeline(s) and stage set. Compare against the recommended shape for this site's taxonomy (table above):
- **All stages already match (or a superset of) the recommendation** → just note the stage IDs, nothing to create.
- **Some stages are missing** → propose the specific additions to the user (e.g. *"Your pipeline has 'New' and 'Won' but no 'Contacted' or 'Qualified' — want me to add those?"*) and create them via the admin/builder API on confirmation — don't silently add stages to a client's live CRM without asking, since it changes what their whole team sees.
- **No pipeline/deal tracking makes sense at all** (e.g. plain T2/T3 e-commerce per the table) → skip deal creation entirely; a Contact alone may be all that's needed.

**Wire the form handler.** With the SITE token (`Authorization: Bearer`), upsert the Contact (search by email → create/update) and create a Deal for the enquiry, associated to the contact, using the **entry stage** identified/created above (e.g. "Appointment Requested" or "New Enquiry" — NOT a later stage like "Confirmed"/"Appointment Scheduled", since the visitor has only just asked). Stage **ids are account-specific** — **do NOT read them with the SITE token at request time**: `GET /crm/v3/pipelines/deals` needs `crm.objects.deals.read`/`crm.schemas.deals.read`, which the SITE token deliberately excludes (§ above). Instead, look up the pipeline/stage IDs **once** during the pipeline-design step above, then **hardcode those IDs in the endpoint code** (pipeline configs rarely change; if they ever do, redeploy). If you omit `dealstage`, HubSpot uses the pipeline's default first stage, which may be wrong. When **verifying** a just-created deal, use a direct list/GET (`GET /crm/v3/objects/deals` or `/{id}`) — the search endpoint (`POST /crm/v3/objects/deals/search`) lags a few seconds (eventually-consistent index). CRITICAL: **fail safe** — if HubSpot is unconfigured or errors, still return success to the visitor and log it; never lose a lead.

**Optional: give HubSpot visibility over a customer-facing confirmation email sent via another service (e.g. Resend, see §5).** HubSpot's own transactional-email sending requires Marketing Hub Professional/Enterprise ($800+/month) — not viable for most SMEs. Cheaper alternative: send the actual email with a transactional provider, then log it as an HubSpot **email engagement** so it shows up on the contact's timeline: `POST /crm/v3/objects/emails` with `properties: {hs_timestamp, hs_email_direction: "EMAIL", hs_email_status: "SENT", hs_email_subject, hs_email_text}` and an `associations` array linking it to the contact (and deal, if relevant). Community reports suggest the existing `crm.objects.contacts.write` scope covers this (no confirmed separate `crm.objects.emails.*` scope requirement) — **verify live**; if it 403s on missing scope, add the minimal `crm.objects.emails.write` scope to the SITE token.

**Spam protection (Cloudflare Turnstile) — add before going live for any public lead/reservation form.** Create a **managed Turnstile widget** via the Cloudflare API (`POST https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/challenges/widgets`, `mode: "managed"`, `domains: ["<project>.pages.dev"]`) → the **sitekey is public** (store as a public env var `PUBLIC_TURNSTILE_SITE_KEY`; for prerendered Astro pages inline it at build via `import.meta.env`) and the **secret** is a Cloudflare Pages secret `TURNSTILE_SECRET_KEY`. The form renders the widget and sends its token; the server endpoint **verifies it via `POST https://challenges.cloudflare.com/turnstile/v0/siteverify`** (form-encoded `secret` + `response` + `remoteip` from the `CF-Connecting-IP` header) **BEFORE** creating any Contact/Deal, returning 403 on failure. **Fail-open only when `TURNSTILE_SECRET_KEY` is unset** (rollout safety), enforced once set.

## 2. Payments — Stripe

For anything that takes money on the site: T3 checkout, T4 deposits/prepayment, T5 recurring billing, or simple few-SKU T2 sales.
- **Connect** (run foreground): per `claudeconnectorskillheadless/connectorskill.md` (its Stripe row — claude.ai connector, R+W: payments/customers/invoices/refunds) for builder access.
- **Deep links (confirmed working, skip Stripe's dashboard menu hunting) — auto-route to whichever account/mode is active in the browser:** create a restricted API key directly at `dashboard.stripe.com/test/apikeys/create`, create a webhook endpoint directly at `dashboard.stripe.com/test/webhooks/create` (drop `/test` from either for live mode).
- **Site-runtime restricted key — Dashboard-only, confirmed empirically the connector cannot mint this.** The claude.ai Stripe connector's OAuth credential is builder-access only; the site's own runtime key must be created by hand — use the deep link above, or manually **Dashboard → Developers → API keys → Create restricted key**:
  1. First screen, "How will you be using this key?" → **"Powering an integration you built"** (NOT "Providing this key to a third-party application" — that option is for handing the key to an external app/plugin, not your own site's code).
  2. Setting permissions: the list is long, grouped under **bold category-header rows that bulk-toggle the whole category** (e.g. "Billing" would also grant Batch Jobs/Meters/Billing Alerts/etc.) — never use these. Instead use the page's **search box**, one resource at a time, and set only that row.
  3. Each resource is a **single None/Read/Write selector, not two checkboxes** — Write already implies Read.
  4. Typical **T5 membership/subscription** minimum (Checkout Session creation + webhook receiver + Customer Portal link): search "checkout" → **Checkout Sessions** → Write; search "customer" → **Customers** → Write; search "subscription" → **Subscriptions** → Read; search "portal" → **Customer portal** (may display as "Billing Portal") → Write. Adjust the set per taxonomy/flow — this is the T5 baseline, not a universal list.
  5. Name the key (e.g. "Website") → Create. The secret is shown once — store it immediately as the Pages secret `STRIPE_SECRET_KEY` (never the full secret key if a restricted one suffices).
- **Wiring — prefer Stripe-hosted surfaces.** Default to **Payment Links** (zero site-side code — a link/button, good for a handful of products) or **Stripe Checkout sessions** (an Astro server endpoint creates the session and redirects, using the restricted key above). Either way **card data never touches the site** (PCI stays Stripe's problem). Avoid embedding raw card fields (Elements) unless the user has a strong reason.
- **Fulfillment via webhooks:** a Pages Function endpoint receiving Stripe webhooks (verify the signature with the webhook signing secret, stored as a Pages secret) — that's where T3 delivers the download (R2 signed URL), T4 confirms the booking, T5 grants access. **Stripe Tax** handles T3's global VAT; **Stripe Billing** handles T5 subscriptions.
- **Create the webhook endpoint — Dashboard-only, same deep-link shortcut as the restricted key above.** Use the deep link, or manually Developers → Webhooks → Add destination (Stripe recently renamed/relocated this — if the menu path isn't obvious, searching "webhooks" in the dashboard's search bar finds it fastest). It's now a multi-step wizard ("Create an event destination"), not a single form:
  1. Step "Select events" → "Configure your event destination" → **Event destination scope**: choose **"Your account"** (NOT "Connected accounts" — that's only for Stripe Connect platforms with sub-accounts, not relevant unless the integration explicitly uses Connect).
  2. Continue → pick the specific events to listen for (e.g. for a T5 membership/subscription integration: `checkout.session.completed` and `customer.subscription.deleted` at minimum — adjust per what the specific webhook receiver code actually handles).
  3. Continue → "Choose destination type" → webhook endpoint (as opposed to e.g. Amazon EventBridge) → enter the deployed receiver's URL (e.g. `https://<site>.pages.dev/api/hooks/stripe`).
  4. Create it — Stripe shows the **signing secret** (`whsec_...`) once at creation time; store it immediately as the Pages secret `STRIPE_WEBHOOK_SECRET`. If lost, it can be revealed/rolled again later from the endpoint's detail page, but treat it as one-time-shown by default.
- **⚠️ Financial guardrail (global rule):** you set up the rails; you never execute transactions, move money, or change payout/billing settings on the client's behalf. Real-money confirmations follow the browser-intervention hand-off rules.

## 3. E-commerce — Shopify

For **T2 (physical goods)** — real inventory, variants, shipping, and a battle-tested checkout are Shopify's job, not something to rebuild on D1.
- **Connect** (run foreground): per `claudeconnectorskillheadless/connectorskill.md` (its Shopify row — claude.ai connector, R+W full Admin via GraphQL) for builder access (products, collections, orders, inventory).
- **Wiring — think through the architecture with the user (three common shapes):**
  1. **Astro marketing site + Shopify Buy Button / cart embeds** — the standard stack stays the face of the business; Shopify handles cart + hosted checkout. Best default for SMEs with a modest catalog.
  2. **Full Shopify storefront** (their theme, possibly on a subdomain like `shop.<domain>`) with the Astro site for brand/content pages — least custom work, most Shopify lock-in of the look.
  3. **Headless via Storefront API** — Astro renders the catalog with a public Storefront-API token (safe for runtime), checkout still Shopify-hosted — most control, most work; only when genuinely needed.
  Present the trade-off (control vs effort vs upkeep) and let the user pick. Checkout stays Shopify-hosted in every shape — never hand-roll card handling.
- If the client sells only a couple of simple items, say so: **Stripe Payment Links (§2) may beat a whole Shopify store** — recommend the lighter option.

## 4. Scheduling / appointments

For **T4** (and consult-based T1). **No single standard tool works for everyone — work it out with the user** rather than defaulting:
- **Does the client already use a booking system** (restaurants, clinics, salons often have entrenched ones)? If so, integrating/embedding it usually beats migrating.
- **Calendly** — easiest connected option (`claudeconnectorskillheadless/connectorskill.md` table: claude.ai connector, R+W — event types, links, availability; run foreground) with a clean embeddable widget; good default for consultations/appointments when the client has no system.
- **Custom booking on the standard stack** (D1 slots + Astro endpoints + email reminders, deposits via Stripe §2) — only when requirements are simple and fixed, or the client refuses a SaaS subscription; you own the upkeep.
- Decide by: existing tooling, need for payments/deposits at booking (→ pairs with Stripe), calendar sync, embed quality, subscription cost. Verify the current landscape live.
- Whatever books the slot, **still create the CRM contact/deal (§1)** so enquiries and bookings land in one pipeline.

### SimplyBook.me — two separate auth tiers, don't confuse them

SimplyBook is a common entrenched booking tool for clinics/salons (see the "already has a system" bullet above). It has **two unrelated API auth paths** — picking the wrong one silently caps you at read-only:

1. **Client/widget tier — `getToken(company_login, api_key)`.** The `api_key` comes from the dashboard's **Account Info → "Custom Features" → API** section. This token is read-mostly and scoped for the public booking widget (available slots, services list, submitting a booking as a visitor) — **it cannot create/edit services, staff, or working hours.** Use it only for embedding/reading, never assume it unlocks admin methods.
2. **Admin tier — `getUserToken(company_login, user_login, api_user_key)`.** This is the real admin auth path and the one that unlocks `addServiceProvider`/`editServiceProvider`/`setWorkDayInfo` and the other ~80 admin methods (services, staff/providers, working hours, bookings management). Needed for any T4 automation that provisions or edits the client's booking setup rather than just reading it.

**Getting the admin credential (verified live against a real account):**
- Dashboard → **Account Info → "For developers" section → User Api Keys** → generate a key there.
- **No separate dashboard user is required** — the generated key is automatically tied to whichever account is currently logged in; `user_login` is that same account's own login/email, shown right on the Account Info page. (An earlier assumption that a dedicated user had to be created first was wrong — don't do that.)
- API User Keys from this form **bypass IP verification**, unlike calling `getUserToken` with a plain dashboard password directly.

**Call pattern:**
```bash
# 1. Mint an admin token (expires in 1 hour — fetch fresh per session/run, don't cache long-term)
curl -X POST https://user-api.simplybook.me/login \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getUserToken","params":["<company_login>","<user_login>","<api_user_key>"],"id":1}'
# -> {"result": "<token>", ...}

# 2. Call admin methods with that token
curl -X POST https://user-api.simplybook.me/admin/ \
  -H "Content-Type: application/json" \
  -H "X-User-Token: <token>" \
  -H "X-Company-Login: <company_login>" \
  -d '{"jsonrpc":"2.0","method":"getUnitList","params":[],"id":1}'
# writes use the same headers, e.g. "method":"addServiceProvider" / "editServiceProvider" / "setWorkDayInfo"
```
- **Token expiry: 1 hour.** Call `getUserToken` fresh at the start of each integration session/run rather than persisting the token.
- Store `api_user_key` as a **local-only** `.env` credential (`chmod 600`, per `claudeconnectorskillheadless/storingsecrets.md`) — this is builder/admin access, never a site-runtime key.
- **What this unlocks:** provisioning/editing services, staff (service providers), and working hours programmatically — the actual gap that otherwise blocks T4 booking-setup automation (previously only the read-mostly widget key was available, so any staff/hours/service change had to be done by hand in the dashboard).

## 5. Transactional email (customer-facing auto-replies) — Resend

Not in `claudeconnectorskillheadless/connectorskill.md`'s table (no claude.ai connector exists) — this is a **simple API key** service, connect per method #3 practices (run foreground, one step at a time, tap-to-copy links).

**When to use:** the owner wants the customer to get an automatic confirmation email after submitting the contact/reservation form ("thanks for reaching out"). This is separate from — and complements — the CRM notification in §1 (HubSpot sees the enquiry; the transactional provider sends the customer-facing reply). Don't confuse it with notifying the *owner* of a new enquiry — that's a separate, simpler need: send the owner a plain notification per submission, most simply through this same Resend setup (just `to:` the owner's address). If you'd rather not set up a transactional provider at all, a Cloudflare **Email Worker** can send it (the `send_email` binding delivers to a *pre-verified* address — fine for a fixed owner inbox; note plain Email Routing only *forwards* inbound mail, it doesn't originate these). Either way it doesn't require the customer-facing transactional flow.

**Why Resend:** instant/automatic signup with no manual approval gate — a prior provider's manual review step stalled a live project mid-build. Resend is also Cloudflare-native and fits this stack's `fetch`-based Pages Functions cleanly. Verify current pricing/free-tier limits live — this drifts.

### Resend runbook

1. **Sign up:** `https://resend.com` (free, no credit card, instant — no approval wait).
2. **Create an API key — CRITICAL PITFALL, read before creating one:** the dashboard **defaults to a send-only "Restricted" key**. A restricted key **cannot create/manage domains** via the API — confirmed live: `POST /domains` with a restricted key returns `401 restricted_api_key`. **You must explicitly pick "Full Access" permission** when creating the key if any domain work (adding/verifying a sending domain) is needed.
   - **Two-key pattern (least privilege):** mint a **Full-Access** key only for one-time domain-admin setup — keep it in `.env` local-only, **never deploy it** to the site. Mint a separate **Restricted (send-only)** key for the site's actual runtime — that's the one that becomes the Cloudflare Pages secret.
3. **Domain verification — pure DNS, no mailbox needed:**
   - Verifying a domain is DNS-based ownership+auth proof (SPF TXT, DKIM TXT, MX for bounce/feedback) — **no inbox/mailbox is required** to send from an address on that domain. A mailbox only matters if the domain also needs to *receive* mail, which is unrelated to sending.
   - Resend recommends verifying a **subdomain** (e.g. `send.<domain>`) rather than the root domain, to protect the root domain's sender reputation.
   - Call `POST https://api.resend.com/domains` with the **Full-Access** key, body `{"name": "send.<domain>"}` — returns the exact DNS records to add (values are generated per-call, domain-specific).
   - Verification is DNS-propagation-dependent (minutes to ~48–72h) — check status in the Resend dashboard (Domains → the domain, "Pending" → "Verified") or `GET /domains/{id}`.
   - **Status stuck at `not_started` after adding records? Don't assume the DNS is wrong.** `not_started` just means Resend hasn't run its automatic check yet, not that verification failed. Before doing any DNS debugging, trigger a manual re-check: `POST https://api.resend.com/domains/{id}/verify` (same Bearer auth, needs the Full-Access key) — cheap, safe, idempotent. Confirmed live: flipped `not_started` → `pending` → `verified` in ~20s with zero DNS changes. Only fall back to field-by-field record comparison / public-resolver checks if status is still stuck after this.
   - **Until verified:** sends only work from the shared `onboarding@resend.dev` address, and only **to the account owner's own verified email** — fine for internal testing, **not usable for real customer-facing email**. Flag this clearly in the project's status notes so a later session doesn't assume it's launch-ready before verification actually completes.
4. **Cloudflare DNS linking (if the domain's zone is on the connected Cloudflare account) — working pattern + pitfalls:**
   - If the domain's zone is on the **same connected Cloudflare account** (`USER_CLOUDFLARE_RW_ALL_*` OAuth bundle), DNS records can be added programmatically via the `mcp.cloudflare.com/mcp` JSON-RPC `execute` tool (the same tool used for Cloudflare Pages secrets elsewhere in this skill) — **NOT** a plain `Authorization: Bearer` REST call to `api.cloudflare.com/client/v4` (that OAuth token is DCR/MCP-scoped and gets rejected with "Invalid format for Authorization header" if hit directly).
   - **Pitfall that broke this twice, with generic sandbox errors** ("Unexpected token 'export'", "Cannot read properties of undefined"): hand-quoting the JS `code` argument for the JSON-RPC call as a shell string is fragile. **Fix: build the JSON-RPC request body with `python3 -c "import json; print(json.dumps(...))"`** (or equivalent structured serialization) instead of hand-escaping strings in bash — confirmed live to fix it.
   - First call: list zones filtered by the domain name to get the `zone_id` (`cloudflare.request({method:'GET', path:'/zones', query:{name:'<domain>'}})`).
   - **Check for existing/conflicting records at the target host BEFORE adding new ones** — never blindly overwrite; it may be a live shared domain with other services depending on existing records.
   - Add each Resend-specified record via `cloudflare.request({method:'POST', path:'/zones/{zone_id}/dns_records', body:{...}})`, then **read back to confirm**.
   - Rebuild the JSON-RPC helper as a scratch script each session (e.g. `cf-execute.sh`, taking the JS code string as an argument) — it lives in scratchpad, not committed to the repo, matching this skill's existing convention for the Cloudflare execute helper (see the credential note pattern used for Cloudflare Pages secrets elsewhere in this skill).
   - **If the zone is NOT on the connected account:** don't force it — fall back to giving the owner the exact DNS records to paste into wherever they manage that domain's DNS themselves.
5. **Store the token** as a Cloudflare Pages env var `RESEND_API_KEY` (`secret_text`, prod + preview) — the **send-only restricted key**, never the Full-Access one — never in git.
6. **Send:** `POST https://api.resend.com/emails` with `Authorization: Bearer <key>`, simple JSON body `{"from": "<verified-address>", "to": "<customer-email>", "subject": "...", "html": "..."}`. Read the key via the Cloudflare adapter runtime env pattern — `locals.runtime.env.RESEND_API_KEY` — same as other secrets in this skill, **not** `import.meta.env`.
7. **Fail-safe:** if the Resend call errors, still return success to the visitor and log the failure — never block/lose the form submission over an email-send failure (same principle as the CRM fail-safe in §1).

**No inbox:** Resend is send-only — there's no human-readable mailbox to check. Confirmation emails land in whatever the recipient's normal email client is; nothing new for the owner to log into.

## 6. Membership / authentication — Clerk + HubSpot

For **T5 membership** (and any site needing gated member-only areas, a self-service profile page, or social login): recommend **Clerk** (managed auth) as the identity layer and **HubSpot as the single source of truth** for entitlement. Clerk proves *who* is logged in (issues a verifiable session JWT, ships a pre-built account widget, and owns Apple's client-secret rotation for you); HubSpot answers *is this person a member and at what tier* via custom Contact properties. Keep them decoupled: identity ≠ entitlement. Don't hand-roll OAuth — Apple Sign In alone needs a $99/yr Developer Program, a rotating JWT client secret, and strict redirect verification; a managed provider removes exactly the upkeep this stack avoids elsewhere. **Stripe billing (§2) and Shopify member-discount sync (§3) are optional downstream modules** — a member can exist purely from a manual HubSpot grant with no billing object.

**Architecture (each access check):** verify the Clerk session server-side → resolve the HubSpot contact (by a stored `clerk_user_id` first, verified email as fallback — never a contact ID from the browser) → read `membership_status`. Gate via Astro/Pages middleware; cache the HubSpot lookup ~1–2 min to stay under rate limits. The `/members` profile endpoint must resolve the target contact **only** from the authenticated session, never from a client-supplied ID/email — that's the single hard cross-account-safety rule.

### Clerk dashboard setup (owner, one-time)
1. Create the Clerk application. Build/test on a **test-mode instance** (`pk_test_`/`sk_test_`) — fine while the site is still behind a preview gate — but **switch to a Production instance (`pk_live_`/`sk_live_`) before real public launch.**
2. Enable factors: Email → **magic link** (Clerk sends its own verification emails — no Resend/transactional-email dependency for login), plus **Google** under Social connections. **Apple is optional — defer it** unless the owner will pay the **$99/yr Apple Developer Program** (needed for the Services ID + `.p8` key Clerk asks for); magic-link + Google alone is a valid launch config.
3. Add the site's domain(s) (`<project>.pages.dev` and any custom domain) to Clerk's **allowed origins / redirect URLs**.
4. Create the webhook: endpoint `https://<site>/api/hooks/clerk` (convention: `functions/api/hooks/clerk.ts`), subscribe to **`user.created`**, and copy the **signing secret** — verify it in the receiver (Svix signature; doable with Web Crypto, no `svix` dep).

### Env vars (Cloudflare Pages, prod + preview)
| Env var | Type | Notes |
|---|---|---|
| `PUBLIC_CLERK_PUBLISHABLE_KEY` | `plain_text` | Client-safe publishable key (`pk_...`). |
| `CLERK_SECRET_KEY` | `secret_text` | Backend secret (`sk_...`) — session verify + Clerk backend API. |
| `CLERK_WEBHOOK_SECRET` | `secret_text` | Signing secret (`whsec_...`) for the `user.created` receiver. |

### Recommended HubSpot property set
Create these **once** (see the schema-scope note below), grouped under a "Membership" property group. Six Contact + one Deal property:

| Object | Internal name | Label | Field type | Options |
|---|---|---|---|---|
| Contact | `membership_status` | Membership Status | enumeration | `none`, `active`, `comp`, `cancelled`, `past_due` |
| Contact | `membership_tier` | Membership Tier | enumeration | `standard`, `silver`, `gold` |
| Contact | `membership_since` | Member Since | date | — |
| Contact | `clerk_user_id` | Clerk User ID | string (single-line) | maps Clerk identity → contact by stable ID |
| Contact | `email_verification_status` | Email Verification Status | enumeration | `unverified` (default), `verified` |
| Contact | `merged_from_lead_at` | Merged From Lead At | date (with time) | backend audit only; never member-facing |
| Deal | `lead_verification_status_at_creation` | Verification Status (at creation) | enumeration | `unverified`, `verified` |

`membership_status` is the **one** field every gate reads (`active`/`comp` ⇒ allow). `stripe_customer_id`/`stripe_subscription_id` (string) are added only if Stripe billing (§2) is wired.

**Create them with a schema-scoped private-app token, called directly.** First create the dedicated `membership` property group (see "Group new custom properties by API" under "Watch out for" below), then set each property's `groupName` to it — **not** the default `contactinformation`:
```bash
curl -X POST https://api.hubapi.com/crm/v3/properties/contacts \
  -H "Authorization: Bearer $HUBSPOT_SCHEMA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"membership_status","label":"Membership Status","type":"enumeration",
       "fieldType":"select","groupName":"membership",
       "options":[{"label":"None","value":"none"},{"label":"Active","value":"active"},
                  {"label":"Comp","value":"comp"},{"label":"Cancelled","value":"cancelled"},
                  {"label":"Past due","value":"past_due"}]}'
```
(Deal properties: `POST .../properties/deals`. Expect `201` per property.)

### Verified vs. unverified — the core pattern (and the account-linking trap)
- **`email_verification_status`** on the Contact separates "is a real member" (`membership_status`) from "has proven they own this email" (`email_verification_status`). Every plain contact-form Contact defaults `unverified`; **only Clerk** (which actually checks ownership) may set `verified`. Never expose `/members` or a member discount to an `unverified` lead.
- **`lead_verification_status_at_creation`** on the Deal is a **frozen snapshot**, not a live link: stamp it from the Contact's status *at the moment the Deal is created*, so old enquiries keep showing what was true then even after the person later verifies. (Both are plain enumerations — surface them as a column/pill on the Contacts/Deals board, no code.)
- **The trust trap — do NOT auto-surface old lead data to a new member.** When a Clerk signup's verified email matches a pre-existing (unverified) Contact, merging the records **on the backend** for the owner's reporting continuity is correct and standard (Lead→Contact conversion). But the **member-facing** `/members` profile must be built from *only* two sources: Clerk-verified identity fields + what the member themselves types. **Never pre-fill** old `firstname`/`lastname`/`phone`/enquiry text from that pre-existing record — it could be a typo, a stranger's email, or fabricated, and showing it to the real member as "their" data is itself the harm. Divert any conflicting old value to an internal **HubSpot Note**, not a live field. (This isn't hypothetical: Auth0 *removed* automatic account-linking-by-email after it was flagged as an account-hijack risk — a verified-email match is necessary but not sufficient for a silent merge.) Entitlement is never inferred from old webform data either — `membership_status` only ever comes from Clerk + Stripe/manual grant.

### Watch out for
- **Framework-mismatched env var names.** Clerk's dashboard "Quick copy" defaults to a **Next.js** snippet (`NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY`); Astro's `@clerk/astro` needs **`PUBLIC_CLERK_PUBLISHABLE_KEY`** (no `NEXT_` prefix) — same key value, wrong var name if copied blindly. Check the page's framework selector matches the project before copying.
- **Cloudflare Pages `nodejs_compat` flag — set it on the SAME deploy that adds Clerk.** The Clerk/Astro middleware bundle imports Node built-ins (`node:fs` etc.) the Workers runtime lacks by default. Without `nodejs_compat` on **both** the `production` **and** `preview` compatibility flags, every Clerk-gated route hard-500s (`Error: No such module "node:fs"`) while ungated pages look fine — easy to miss until someone visits a gated page. Add the flag before/during that deploy, don't discover it live.
- **HubSpot private-app scopes: the "Auth" tab is read-only.** Scopes are added/edited from the **"Overview" tab's scope editor** (search → tick → save), not the Auth tab (which only *displays* granted scopes). Someone can genuinely believe they added a scope and have it not be there — after saving, re-check the Auth tab **and** test-call the endpoint. A `POST /crm/v3/properties/{objectType}` returning `403` with `"category":"MISSING_SCOPES"` + a `requiredGranularScopes` list is the unambiguous "scope isn't active yet" signal — don't trust the UI alone.
- **No connector-based schema creation.** A generic HubSpot connector/MCP (object read/write via `crm.objects.*`) **cannot create custom property definitions** — that needs **`crm.schemas.<object>.write`** specifically, on a private-app token, called directly (`POST .../properties/{objectType}` with `name`, `label`, `type`, `fieldType`, `groupName`, and `options[]` for enumerations). This is a **one-time, narrowly-scoped elevation** — the routine site `HUBSPOT_TOKEN` stays object-level only; don't leave the schema-write scope active longer than needed.
- **"Sign up before properties exist" silently loses data — replay, don't hand-patch.** If a member registers via Clerk before the HubSpot properties exist, the webhook's write silently no-ops (correct fail-safe: no crash, but no retry). The fix is **not** editing the CRM record by hand — it's **replaying the original Clerk webhook event** (Clerk dashboard → Webhooks → endpoint → Message Attempts → Replay) once the properties exist, so the exact original registration logic re-runs (correct merge/dedup, sets `clerk_user_id` and all fields).
- **Notes need their own scope.** Writing the merge/conflict HubSpot Notes above needs `crm.objects.notes.write` on the site token; without it those Note writes are skipped (logged, non-fatal) — everything else still works.
- **A site-wide Zero Trust preview gate silently blocks the Clerk webhook (and EVERY other inbound webhook).** If the site is gated for pre-launch preview via a whole-domain Cloudflare Zero Trust Access app (SKILL.md step 7), that gate intercepts **all** requests to the domain *before* they reach the site's code — including server-to-server calls with no browser or human behind them, like Clerk's `user.created` POST to `/api/hooks/clerk`. Clerk's request gets 302'd to the Access login page (`www-authenticate: Cloudflare-Access`), never runs the receiver, and Svix retries then gives up — so a real signup is **never written to HubSpot**, with **no visible site error** (it fails silently on the delivery side). **Fix:** add a narrow, **path-scoped Access `bypass` application** for the exact webhook path (`<project>-website.pages.dev/api/hooks/clerk`), decision `bypass`, include `everyone` — mirroring the CMS admin-route bypass already used for `/admin` (or `/api/keystatic`). Verify with an unauthenticated `curl -I` to the path: it should reach the site's code (e.g. a `400`/`401` from signature verification), **not** 302 to `*.cloudflareaccess.com`. This is safe **only because** webhook endpoints verify a cryptographic signature (Clerk/Svix, Stripe, and HubSpot workflow webhooks all do) — the bypass removes the login *wall*, not authentication of the request itself. This applies to **any** later webhook-receiving integration, not just Clerk — see SKILL.md step 7's callout.
- **Group new custom properties by API; the contact "highlights" card needs a manual follow-up.** Whenever a workflow creates ≥3-4 related custom properties (e.g. a membership/subscription feature), create a dedicated property group and assign it by default — don't leave them scattered under a generic default group: `POST /crm/v3/properties/{objectType}/groups` (`{"name":"...", "label":"..."}`), then set each property's `groupName` to it (at creation, or `PATCH .../properties/{objectType}/{propertyName}` after the fact). That part is fully automatable. **Separately**, HubSpot's default record "About this contact" summary/highlights card does **not** auto-show new custom properties, and there is **no public API to configure it** (confirmed empirically) — it's a portal-level, UI-only setting (Settings → Objects → [object] → record customization, or the summary card's own edit icon on any record → "Customize properties"/"Customize record"; exact wording drifts, hedge when instructing). Non-technical owners read "not on the card" as "the data isn't there" and panic. **Don't wait for that call** — as soon as the workflow adds properties an owner will check regularly, (a) group them via the API above, and (b) proactively send the ~30-second manual steps: open any record of that object type → the summary card's edit/actions icon → "Customize properties" (or "Customize record") → add the new group/properties → Save (portal-wide, one-time).

## 7. Anything else — scan the connector table, prioritize easy connectors

For needs beyond the above, **scan `claudeconnectorskillheadless/connectorskill.md`'s per-service table first** and prefer services with an easy path (claude.ai connector > simple API key > OAuth runbook). Common SME adds:
- **Email marketing / newsletters** — Klaviyo (connector) or Mailchimp (API key); wire signup forms server-side like the CRM form handler (minimal-scope key in Pages env).
- **Accounting / invoicing** — QuickBooks (connector) or Xero (see `xeroconnect.md`); builder-side only, nothing in the site runtime.
- **Support / chat** — Intercom / Zendesk (API tokens); usually a widget embed — the runtime needs at most a public widget key.
- **Analytics** — **Cloudflare Web Analytics** is the default (same Cloudflare account, no third-party signup), but it isn't automatic: enable it for the site and add its beacon snippet during the build (SKILL.md step 12). GA4 only if the client insists (see `googleanalyticsconnect.md`).
- **Social / ads** — Meta / Instagram / WhatsApp via `metaconnect.md` when marketing work is in scope.

Don't connect anything speculatively: propose the shortlist matching the taxonomy + the user's stated needs, confirm, then connect one at a time (each per its `claudeconnectorskillheadless/connectorskill.md` row, run foreground) and record what's connected — and how it's wired — in the project `CLAUDE.md`.
