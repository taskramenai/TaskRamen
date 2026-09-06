# Website Access Reference

How to pick a tool for fetching web content, and what to do when a site doesn't
cooperate. **Default for all real sites: `npx agent-browser --cdp 9222`**
(persistent Chrome with a real profile).

---

## Tool priority

| Site behaviour | Tool |
|---|---|
| Structured data available from an API | that API (SerpAPI engines below) |
| Publisher offers a feed or JSON endpoint | `curl` that endpoint — cheaper and more stable than scraping |
| Simple static HTML | WebFetch (last resort) |
| JS-rendered | agent-browser `--cdp 9222` |
| Requires a session you are already logged into | agent-browser `--cdp 9222` (uses the persistent profile) |

**Never** run `agent-browser open` without `--cdp 9222` — that launches a clean
throwaway browser with none of the user's sessions.

---

## Search & Data APIs (preferred over scraping)

### SerpAPI (direct REST API)
- **Use for:** general search, plus the `google_flights`, `google_hotels`,
  `google_maps` and `google_finance` engines
- **Always pass:** `currency: "<user's currency>"` for travel (infer from the
  country in personalinfo.md, e.g. `USD`, `EUR`)
- **Large results:** hotel and flight responses can exceed 100 KB — save to a
  file and parse with Python/jq rather than reading raw JSON
- **How to call:** `GET https://serpapi.com/search?engine=<engine>&...&api_key=$SERPAPI_KEY`.
  Load the key from `.env` in the same command
  (`set -a; source "$CLAUDE_HOME/.env"; set +a`) so a newly-connected key works
  without a restart. Works in background agents.

---

## When a site won't serve you

Sites decline automated access for a range of reasons, and the right response
depends on which one you're hitting.

**Paywall or login wall.** If the user has a subscription, the persistent Chrome
profile may already be logged in — try `--cdp 9222` first. If it isn't, do not
try to get around the wall: ask the user, or use a source that is free to read.
Many publishers offer RSS or a public API covering the same stories; prefer that.
Note that feeds often lag the live site by a day or more, so say so when it
matters to the answer.

**Captcha or bot-check page.** Treat this as a permanent failure for that
session. Do not retry, and do not attempt to solve the challenge — the site is
asking for a human. Either hand off to the user via the browser viewer (see the
browser-intervention skill) if they specifically need that page, or switch to a
different source. Note that a screenshot at this point captures the challenge
page, not the content.

**Regional or network-level blocks.** Some domains are unreachable from a given
country or network, which can surface as a DNS failure, a redirect to an
unrelated host, or a TLS certificate mismatch. This is not a bug to work around —
record it and use an alternative source.

**Rate limiting (HTTP 429).** Back off; don't hammer. If you need many pages from
one site, check whether it publishes a bulk or API endpoint instead.

Whichever applies: record what you tried and what happened, so the next attempt
doesn't repeat it. If a particular site matters to you repeatedly, add a short
note for it in your own project's `CLAUDE.md` rather than here.

---

## Robots and terms

Prefer official APIs and feeds over scraping. Respect `robots.txt`, rate limits
and the site's terms of service. The browser profile exists so the assistant can
use sessions the user is already entitled to — not to reach content they aren't.
