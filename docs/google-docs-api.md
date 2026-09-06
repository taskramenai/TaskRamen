# Google Docs API Reference

Use the Docs REST API directly (no MCP).

Credentials live in `.env` under the `SERVICE_GOOGLE_WORKSPACE_RW_` prefix (see CLAUDE.md "Google Workspace"):
`SERVICE_GOOGLE_WORKSPACE_RW_CLIENT_ID`, `SERVICE_GOOGLE_WORKSPACE_RW_CLIENT_SECRET`, `SERVICE_GOOGLE_WORKSPACE_RW_REFRESH_TOKEN`.

## Get access token
```js
const fs = require('fs');
function envCreds() {
  const txt = fs.readFileSync((process.env.CLAUDE_HOME || process.env.HOME) + '/.env', 'utf8');
  const get = k => { const m = txt.match(new RegExp('^' + k + '=\\s*([^#\\r\\n]*?)\\s*(?:#.*)?$', 'm')); return m ? m[1].trim().replace(/^["']|["']$/g, '') : (process.env[k] || ''); };
  return { client_id: get('SERVICE_GOOGLE_WORKSPACE_RW_CLIENT_ID'), client_secret: get('SERVICE_GOOGLE_WORKSPACE_RW_CLIENT_SECRET'), refresh_token: get('SERVICE_GOOGLE_WORKSPACE_RW_REFRESH_TOKEN') };
}

async function getAccessToken() {
  const creds = envCreds();
  const body = new URLSearchParams({
    client_id: creds.client_id, client_secret: creds.client_secret,
    refresh_token: creds.refresh_token, grant_type: 'refresh_token'
  }).toString();
  const res = await httpsPost('oauth2.googleapis.com', '/token', body, 'application/x-www-form-urlencoded');
  return res.access_token;
}
```

## Fetch document JSON
```js
async function getDocument(token, docId) {
  return await httpsGet('docs.googleapis.com', `/v1/documents/${docId}`, token);
}
```
Table cells have exact `startIndex`/`endIndex` in `content[].paragraph`.

## Build requests
```js
function makeReplaceRequest(cell, newText) {
  const para = cell.content?.[0];
  const startIndex = para.startIndex;
  const endIndex = para.endIndex - 1; // exclude \n
  if (startIndex === endIndex) {
    return { insertText: { location: { index: startIndex }, text: newText } };
  }
  return [
    { deleteContentRange: { range: { startIndex, endIndex } } },
    { insertText: { location: { index: startIndex }, text: newText } }
  ];
}
```

## Send — sort DESCENDING first (critical)
```js
requests.sort((a, b) => {
  const idx = r => r.insertText?.location?.index ?? r.deleteContentRange?.range?.startIndex ?? 0;
  return idx(b) - idx(a);
});
await httpsPost('docs.googleapis.com', `/v1/documents/${docId}:batchUpdate`,
  JSON.stringify({ requests }), 'application/json', token);
```

## Iterate table
```js
const table = doc.body.content.find(e => e.table)?.table;
for (let i = 1; i < table.tableRows.length; i++) { // skip header row
  const cells = table.tableRows[i].tableCells;
}
```

## Delete range
```js
// Never delete the very last char — Docs requires ≥1 char at end
{ deleteContentRange: { range: { startIndex: start, endIndex: docEnd - 1 } } }
```

## Appending text (non-table)
For a simple append to the end of the body, use a single `insertText` request at the end index of the body (or `endOfSegmentLocation`):
```js
{ insertText: { endOfSegmentLocation: {}, text: "..." } }
```

Working example: `examples/docs-example.js` (generic, copy as starting point)

## Rich formatting — headings, bullets, tables from scratch

For anything beyond plain text or updating an existing table's cells (real heading styles,
bullet lists, or inserting a brand-new table), use `examples/docs-format-example.js`. It exports
`buildFormattedDoc(token, docId, blocks)`, which takes a simple block-list model —
`{ style: 'H1'|'H2'|'H3'|'P'|'BULLET', text }` or `{ table: { header: [...], rows: [[...]] } }`
— and handles:

- Inserting all block text in one pass while tracking each block's character offset, so heading
  (`updateParagraphStyle` → `HEADING_1/2/3`) and bullet (`createParagraphBullets`) styles can be
  applied afterward without re-fetching the document.
- Inserting a new table (`insertTable`) and filling its cells.
- Bolding the table's header row once filled.

**Non-obvious gotcha:** `insertTable` at a requested `location.index` can land the table's real
`startIndex` **one position later** than requested — Docs silently inserts an empty paragraph
immediately before the table. Matching the just-inserted table by exact index will intermittently
fail. Re-fetch the document and match with a small tolerance range instead, e.g.:

```js
const tableEl = freshDoc.body.content.find(
  e => e.table && e.startIndex >= requestedIndex && e.startIndex <= requestedIndex + 2
);
```

`examples/docs-format-example.js` handles this internally — see its inline comment for the full
insert-placeholder → insertTable → re-fetch-and-match-with-tolerance → fill-cells → bold-header
sequence.
