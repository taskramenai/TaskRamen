# Google Workspace REST API Reference (Gmail / Calendar / Sheets / Drive)

No MCP. All calls are plain HTTPS with `Authorization: Bearer <access_token>`.
Credentials live in `.env` under the `SERVICE_GOOGLE_WORKSPACE_RW_` prefix (see CLAUDE.md
"Google Workspace"). The connected account is `$SERVICE_GOOGLE_WORKSPACE_RW_EMAIL`
(== `<SERVICE_EMAIL>`).

For Docs and Slides, see `docs/google-docs-api.md` and `docs/google-slides-api.md`.

---

## Auth — get a fresh access token

The stored `SERVICE_GOOGLE_WORKSPACE_RW_ACCESS_TOKEN` is short-lived (~1h). On any `401`,
mint a new one from the refresh token. Two equivalent ways:

**Option A — vendored script (preferred), then persist the new token:**
```bash
set -a; source "$CLAUDE_HOME/.env"; set +a   # load SERVICE_GOOGLE_WORKSPACE_RW_* into the environment
node "$CLAUDE_HOME/claudeconnectorskillheadless/refresh.mjs" \
  --token-endpoint "$SERVICE_GOOGLE_WORKSPACE_RW_TOKEN_ENDPOINT" \
  --client-id "$SERVICE_GOOGLE_WORKSPACE_RW_CLIENT_ID" \
  --refresh-token-env SERVICE_GOOGLE_WORKSPACE_RW_REFRESH_TOKEN \
  --client-secret-env SERVICE_GOOGLE_WORKSPACE_RW_CLIENT_SECRET
# → {"event":"credentials","access_token":"ya29...","refresh_token":"...",...}
# Write the new access_token back into .env (SERVICE_GOOGLE_WORKSPACE_RW_ACCESS_TOKEN), chmod 600.
```

**Option B — inline, self-contained Node helper** (reads `.env` directly; use this
at the top of any script below):
```js
const fs = require('fs');
const https = require('https');

function envGet(k) {
  const txt = fs.readFileSync((process.env.CLAUDE_HOME || process.env.HOME) + '/.env', 'utf8');
  const m = txt.match(new RegExp('^' + k + '=\\s*([^#\\r\\n]*?)\\s*(?:#.*)?$', 'm'));
  return m ? m[1].trim().replace(/^["']|["']$/g, '') : (process.env[k] || '');
}

function httpsRequest(method, hostname, path, headers, body) {
  return new Promise((resolve, reject) => {
    const req = https.request({ method, hostname, path, headers }, res => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => { try { resolve(JSON.parse(data)); } catch { resolve(data); } });
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

async function getAccessToken() {
  const body = new URLSearchParams({
    client_id: envGet('SERVICE_GOOGLE_WORKSPACE_RW_CLIENT_ID'),
    client_secret: envGet('SERVICE_GOOGLE_WORKSPACE_RW_CLIENT_SECRET'),
    refresh_token: envGet('SERVICE_GOOGLE_WORKSPACE_RW_REFRESH_TOKEN'),
    grant_type: 'refresh_token',
  }).toString();
  const res = await httpsRequest('POST', 'oauth2.googleapis.com', '/token',
    { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(body) }, body);
  if (!res.access_token) throw new Error('Token error: ' + JSON.stringify(res));
  return res.access_token;
}

const J = token => ({ Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' });
```

curl variant for one-off calls (assumes a fresh `$TOKEN`):
```bash
TOKEN="$SERVICE_GOOGLE_WORKSPACE_RW_ACCESS_TOKEN"   # refresh first if expired (see above)
curl -s -H "Authorization: Bearer $TOKEN" https://www.googleapis.com/oauth2/v2/userinfo
```

---

## Gmail

Base: `https://gmail.googleapis.com/gmail/v1/users/me`. `me` resolves to the
connected account.

### Send an email
Gmail wants a base64url-encoded RFC-822 message in the `raw` field.
```js
async function sendEmail(token, { to, subject, text, from }) {
  const msg = [
    `From: ${from}`, `To: ${to}`,
    `Subject: ${subject}`,
    'Content-Type: text/plain; charset="UTF-8"',
    '', text,
  ].join('\r\n');
  const raw = Buffer.from(msg).toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  return httpsRequest('POST', 'gmail.googleapis.com', '/gmail/v1/users/me/messages/send',
    J(token), JSON.stringify({ raw }));
}
// from = envGet('SERVICE_GOOGLE_WORKSPACE_RW_EMAIL')
```
For HTML mail use `Content-Type: text/html; charset="UTF-8"`. For attachments,
build a `multipart/mixed` body before base64url-encoding.

### Search / list messages
```
GET /gmail/v1/users/me/messages?q=<query>&maxResults=20
```
`q` uses Gmail search syntax (e.g. `from:foo@bar.com is:unread newer_than:7d`).
Returns `{messages:[{id,threadId}]}` — fetch each by id.

### Read a message
```
GET /gmail/v1/users/me/messages/{id}?format=full
```
Body text is base64url in `payload.parts[].body.data` (or `payload.body.data` for
simple messages) — decode with `Buffer.from(data, 'base64url').toString()`.

---

## Calendar

Base: `https://www.googleapis.com/calendar/v3`. Use calendar id `primary` (the
connected account's calendar).

### Create an event (with invite)
Adding `attendees` + `sendUpdates=all` emails the invite.
```js
async function createEvent(token, { summary, description, startISO, endISO, timeZone, attendees }) {
  const event = {
    summary, description,
    start: { dateTime: startISO, timeZone },   // e.g. '2026-07-01T15:00:00', 'Asia/Singapore'
    end:   { dateTime: endISO,   timeZone },
    attendees: (attendees || []).map(email => ({ email })),
  };
  return httpsRequest('POST', 'www.googleapis.com',
    '/calendar/v3/calendars/primary/events?sendUpdates=all',
    J(token), JSON.stringify(event));
}
// Always include <MY_EMAIL> (personalinfo.md) in attendees by default.
```
All-day events: use `start.date`/`end.date` (`YYYY-MM-DD`) instead of `dateTime`.

### List upcoming events
```
GET /calendar/v3/calendars/primary/events?timeMin=<RFC3339>&singleEvents=true&orderBy=startTime&maxResults=20
```

### Update / delete
```
PATCH  /calendar/v3/calendars/primary/events/{eventId}?sendUpdates=all   (partial body)
DELETE /calendar/v3/calendars/primary/events/{eventId}?sendUpdates=all
```

---

## Sheets

Base: `https://sheets.googleapis.com/v4/spreadsheets`.

### Create a spreadsheet
```js
httpsRequest('POST', 'sheets.googleapis.com', '/v4/spreadsheets',
  J(token), JSON.stringify({ properties: { title: 'My Sheet' } }));
// → response.spreadsheetId
```

### Read values
```
GET /v4/spreadsheets/{id}/values/{range}      e.g. range = Sheet1!A1:D50
```
Returns `{values: [[...row...], ...]}` (missing trailing empties are omitted).

### Write values (overwrite a range)
```js
httpsRequest('PUT', 'sheets.googleapis.com',
  `/v4/spreadsheets/${id}/values/${encodeURIComponent(range)}?valueInputOption=USER_ENTERED`,
  J(token), JSON.stringify({ values: [['a', 'b'], ['c', 'd']] }));
```

### Append rows
```js
httpsRequest('POST', 'sheets.googleapis.com',
  `/v4/spreadsheets/${id}/values/${encodeURIComponent(range)}:append?valueInputOption=USER_ENTERED`,
  J(token), JSON.stringify({ values: [['new', 'row']] }));
```
`valueInputOption`: `USER_ENTERED` (parses formulas/dates like the UI) vs `RAW`.
For formatting, merges, etc. use `POST /v4/spreadsheets/{id}:batchUpdate`.

---

## Drive

Base: `https://www.googleapis.com/drive/v3`.

### Share a file (grant access + notify)
```js
async function shareFile(token, fileId, email, role = 'writer') {
  return httpsRequest('POST', 'www.googleapis.com',
    `/drive/v3/files/${fileId}/permissions?sendNotificationEmail=true`,
    J(token), JSON.stringify({ role, type: 'user', emailAddress: email }));
}
// Default: share every newly created Doc/Sheet/Slide with <MY_EMAIL>.
```
`role`: `reader` | `commenter` | `writer`. Anyone-with-link: `{role:'reader',type:'anyone'}`
(omit `sendNotificationEmail`).

### Shareable link / metadata
```
GET /drive/v3/files/{fileId}?fields=id,name,webViewLink,owners,permissions
```

### List / search files
```
GET /drive/v3/files?q=<query>&fields=files(id,name,mimeType,modifiedTime)
    e.g. q = name contains 'report' and mimeType = 'application/vnd.google-apps.spreadsheet'
```

---

## Errors & gotchas
- **401 Unauthorized** → access token expired; refresh (see Auth) and retry once.
- **403 with `insufficient` / scope error** → the granted OAuth scopes don't cover
  the call; reconnect with the right scopes (see `claudeconnectorskillheadless/`).
- **429 / quota** → back off and retry.
- Always `encodeURIComponent` A1 ranges and `q` query strings.
- Never write tokens into any file other than `.env` (chmod 600).
