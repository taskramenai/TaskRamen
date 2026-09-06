# Puppeteer Setup Reference

> **SCOPE: Checkout flows and complex multi-step automations only.**
> For browsing, searching, and scraping — use `agent-browser` CLI (`npx agent-browser open/snapshot/click --cdp 9222`). Never write raw Puppeteer/Node.js scripts for tasks that agent-browser can handle.

## Always include `allowDangerous: true` in every MCP Puppeteer tool call.

## Mandatory Interaction Rules
1. Wait at least 2 seconds after `puppeteer_navigate` before any action
2. Scroll element into view before clicking
3. No more than 3 clicks per minute

## Persistent Chrome on port 9222 — always connect, never launch

```js
const puppeteer = require('puppeteer');

async function getConnectedBrowser() {
  try {
    return await puppeteer.connect({ browserURL: 'http://127.0.0.1:9222', defaultViewport: null });
  } catch (err) {
    console.error('Retrying...', err.message);
    await new Promise(r => setTimeout(r, 3000));
    return await puppeteer.connect({ browserURL: 'http://127.0.0.1:9222', defaultViewport: null });
  }
}

(async () => {
  const browser = await getConnectedBrowser();
  const page = await browser.newPage();

  await page.evaluateOnNewDocument(() => {
    Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
    Object.defineProperty(navigator, 'languages', { get: () => ['en-US', 'en'] });
    Object.defineProperty(navigator, 'plugins', { get: () => [1, 2, 3, 4, 5] });
    const orig = window.navigator.permissions.query;
    window.navigator.permissions.query = (p) =>
      p.name === 'notifications' ? Promise.resolve({ state: Notification.permission }) : orig(p);
  });

  try {
    // ... work ...
  } finally {
    await page.close();       // always close tab
    browser.disconnect();     // never browser.close()
  }
})();
```

- Puppeteer at: `$CLAUDE_HOME/node_modules`
- Chrome restarts nightly (during the nightly review) — retry handles `Target closed` errors
- MCP tool launchOptions: `{ "browserWSEndpoint": "http://127.0.0.1:9222" }`

## Google Flights (Puppeteer fallback)
```
https://www.google.com/travel/flights
```
Set One way → origin/dest → date → filter Nonstop. Results in `li` inside `ul[aria-label*="Flights"]`.

## Reddit
Reddit blocks Puppeteer. Use JSON API instead:
```bash
curl -s -A "Mozilla/5.0 ..." "https://www.reddit.com/r/[subreddit]/hot.json?limit=10"
```

## Form Filling Best Practices

**Always read `docs/form-patterns.md` before filling any form.** Key rules:

- **React inputs**: `fill <ref> <value>` may not register. Verify with eval after. Fall back to `page.type()` with `{ delay: 50 }` if value doesn't stick.
- **MUI Date Pickers**: Do NOT navigate month-by-month via the calendar icon. Click the text input and type the date directly (MMDDYYYY for US format, no slashes).
- **Custom dropdowns**: Click to open → wait 500ms → type to filter → click option. Standard `<select>` works with `agent-browser select <ref> <value>`.
- **Autocomplete fields** (city, location): Fill input → wait 1000ms → snapshot -i → click suggestion.
- **Marketing checkboxes**: Always audit and uncheck before submitting any form.
- **Phone numbers**: Always include country code (e.g. `+1…`, `+44…`), or select the country-code dropdown then type local digits. Read the user's number and country code from personalinfo.md.
