// TaskRamen.ai
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

/**
 * Generic Google Docs table updater — reads a doc's table and updates cells via REST API.
 * Copy this as a starting point for any doc-editing task.
 *
 * Usage:
 *   1. Set DOC_ID
 *   2. Populate UPDATE_DATA with your row matches and new values
 *   3. Run: node docs-example.js
 */

const https = require('https');

const DOC_ID = 'YOUR_DOC_ID_HERE';

// Credentials come from .env (SERVICE_GOOGLE_WORKSPACE_RW_* — see CLAUDE.md "Google Workspace").
const fs = require('fs');
function envCreds() {
  const envPath = (process.env.CLAUDE_HOME || process.env.HOME) + '/.env';
  const txt = fs.readFileSync(envPath, 'utf8');
  const get = k => { const m = txt.match(new RegExp('^' + k + '=\\s*([^#\\r\\n]*?)\\s*(?:#.*)?$', 'm')); return m ? m[1].trim().replace(/^["']|["']$/g, '') : (process.env[k] || ''); };
  return {
    client_id: get('SERVICE_GOOGLE_WORKSPACE_RW_CLIENT_ID'),
    client_secret: get('SERVICE_GOOGLE_WORKSPACE_RW_CLIENT_SECRET'),
    refresh_token: get('SERVICE_GOOGLE_WORKSPACE_RW_REFRESH_TOKEN'),
  };
}

// ── Data to write ─────────────────────────────────────────────────────────────
// match: substring to find in any cell of the row (case-insensitive)
// updates: { colIndex: newText } — only the columns you want to change
const UPDATE_DATA = [
  { match: 'Row One Keyword',  updates: { 3: '2026-04-05', 4: 'Status text here' } },
  { match: 'Row Two Keyword',  updates: { 3: '2026-04-05', 4: 'Another status' } },
];

// ── Helpers ───────────────────────────────────────────────────────────────────
function httpsRequest(method, hostname, path, headers, body) {
  return new Promise((resolve, reject) => {
    const req = https.request({ method, hostname, path, headers }, res => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try { resolve(JSON.parse(data)); } catch { resolve(data); }
      });
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

async function getAccessToken() {
  const creds = envCreds();
  const body = new URLSearchParams({
    client_id: creds.client_id,
    client_secret: creds.client_secret,
    refresh_token: creds.refresh_token,
    grant_type: 'refresh_token',
  }).toString();
  const res = await httpsRequest('POST', 'oauth2.googleapis.com', '/token',
    { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(body) }, body);
  if (!res.access_token) throw new Error('Token error: ' + JSON.stringify(res));
  return res.access_token;
}

async function getDocument(token) {
  return httpsRequest('GET', 'docs.googleapis.com', `/v1/documents/${DOC_ID}`,
    { Authorization: `Bearer ${token}` });
}

async function batchUpdate(token, requests) {
  const body = JSON.stringify({ requests });
  return httpsRequest('POST', 'docs.googleapis.com', `/v1/documents/${DOC_ID}:batchUpdate`,
    { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) }, body);
}

function cellText(cell) {
  return cell.content?.map(e =>
    e.paragraph?.elements?.map(pe => pe.textRun?.content || '').join('')
  ).join('').replace(/\n/g, '').trim() || '';
}

function makeReplaceRequests(cell, newText) {
  const para = cell.content?.[0];
  if (!para) return [];
  const startIndex = para.startIndex;
  const endIndex = para.endIndex - 1; // exclude \n terminator
  if (startIndex >= endIndex) {
    return [{ insertText: { location: { index: startIndex }, text: newText } }];
  }
  return [
    { deleteContentRange: { range: { startIndex, endIndex } } },
    { insertText: { location: { index: startIndex }, text: newText } },
  ];
}

// ── Main ──────────────────────────────────────────────────────────────────────
(async () => {
  const token = await getAccessToken();
  const doc = await getDocument(token);

  const tableEl = doc.body.content.find(e => e.table);
  if (!tableEl) throw new Error('No table found in document');
  const table = tableEl.table;
  const tableStartIndex = tableEl.startIndex;

  const requests = [];

  for (let i = 1; i < table.tableRows.length; i++) { // skip header row 0
    const cells = table.tableRows[i].tableCells;
    const rowText = cells.map(cellText).join('|').toLowerCase();

    const entry = UPDATE_DATA.find(e => rowText.includes(e.match.toLowerCase()));
    if (!entry) continue;

    console.log(`Matched row ${i}: ${entry.match}`);

    for (const [colStr, newText] of Object.entries(entry.updates)) {
      const col = parseInt(colStr);
      requests.push(...makeReplaceRequests(cells[col], newText));
    }
  }

  if (requests.length === 0) {
    console.log('No matches found — nothing to update.');
    return;
  }

  // Sort descending by index (critical — prevents index-shifting errors)
  const getIdx = r => r.insertText?.location?.index ?? r.deleteContentRange?.range?.startIndex ?? 0;
  requests.sort((a, b) => getIdx(b) - getIdx(a));

  const result = await batchUpdate(token, requests);
  if (result.error) throw new Error('batchUpdate failed: ' + JSON.stringify(result.error));
  console.log(`Done — ${requests.length} operations applied.`);
})();
