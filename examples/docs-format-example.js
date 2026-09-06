// TaskRamen.ai
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

/**
 * Rich Google Docs builder — turns a simple block-list model into headings, bullet lists,
 * and real tables via the Docs REST API.
 *
 * Handles the fiddly parts that plain `insertText`/table-cell-update scripts don't:
 *   - Sequential text insertion while tracking per-block character offsets, so heading/bullet
 *     styles can be applied afterward without re-fetching the document.
 *   - Heading styles (`updateParagraphStyle` → HEADING_1/2/3) and bullet lists
 *     (`createParagraphBullets`).
 *   - Inserting a brand-new table (`insertTable`) and filling its cells, including the
 *     insertTable index-tolerance gotcha (see comment inline below).
 *   - Bolding a table's header row after it's filled.
 *
 * Copy this as a starting point whenever a doc needs headings/bullets/tables instead of plain
 * text. For the simpler case of just updating cells in an *existing* table, see
 * `examples/docs-example.js`.
 *
 * Usage:
 *   1. Set DOC_ID
 *   2. Build a `blocks` array (see the illustrative example at the bottom)
 *   3. Run: node docs-format-example.js
 */

const https = require('https');
const fs = require('fs');

const DOC_ID = 'YOUR_DOC_ID_HERE';

// Credentials come from .env (SERVICE_GOOGLE_WORKSPACE_RW_* — see CLAUDE.md "Google Workspace").
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
  const creds = envCreds();
  const body = new URLSearchParams({
    client_id: creds.client_id, client_secret: creds.client_secret,
    refresh_token: creds.refresh_token, grant_type: 'refresh_token',
  }).toString();
  const res = await httpsRequest('POST', 'oauth2.googleapis.com', '/token',
    { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(body) }, body);
  if (!res.access_token) throw new Error('Token error: ' + JSON.stringify(res));
  return res.access_token;
}

function authHeaders(token) { return { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }; }

async function getDocument(token, docId) {
  return httpsRequest('GET', 'docs.googleapis.com', `/v1/documents/${docId}`, authHeaders(token));
}

async function batchUpdate(token, docId, requests) {
  const body = JSON.stringify({ requests });
  const res = await httpsRequest('POST', 'docs.googleapis.com', `/v1/documents/${docId}:batchUpdate`,
    { ...authHeaders(token), 'Content-Length': Buffer.byteLength(body) }, body);
  if (res.error) throw new Error('batchUpdate failed: ' + JSON.stringify(res.error, null, 2));
  return res;
}

// Docs indices count UTF-16 code units. Plain BMP text (ASCII, most punctuation) is 1 unit per
// char either way, but anything outside the BMP (emoji, some symbols) is 2 — this makes that
// explicit for anyone copying block text that might include them.
function utf16Len(s) { return Array.from(s).reduce((n, ch) => n + (ch.codePointAt(0) > 0xFFFF ? 2 : 1), 0); }

/**
 * Build a formatted document from a block-list model.
 *
 * @param {string} token  OAuth access token (from getAccessToken())
 * @param {string} docId  Target document ID
 * @param {Array<{style: 'H1'|'H2'|'H3'|'P'|'BULLET', text: string} | {table: {header: string[], rows: string[][]}}>} blocks
 *
 * Appends after whatever content already exists in the doc (fetches the current body end index
 * first) — pass a freshly-created/empty doc for a from-scratch build.
 */
async function buildFormattedDoc(token, docId, blocks) {
  const doc = await getDocument(token, docId);
  const bodyEnd = doc.body.content[doc.body.content.length - 1].endIndex;
  const insertAt = Math.max(1, bodyEnd - 1); // index just before the doc's trailing newline
  const offset = localIndex => insertAt + localIndex; // shift block-local offsets into document space

  // 1. Build the full text blob up front, tracking per-block character offsets so heading/bullet
  //    styles can be applied afterward without re-fetching. Tables get a placeholder line
  //    (swapped for a real insertTable call in step 4) so offset tracking stays simple.
  let text = '';
  const styledRanges = [];      // { start, end, style: 'H1'|'H2'|'H3' }
  const bulletRanges = [];      // { start, end } — contiguous runs of BULLET blocks
  const tablePlaceholders = []; // { start, end, table: { header, rows } }
  let curBulletStart = null;

  for (const b of blocks) {
    if (b.table) {
      if (curBulletStart !== null) { bulletRanges.push({ start: offset(curBulletStart), end: offset(utf16Len(text)) }); curBulletStart = null; }
      const start = utf16Len(text);
      const line = '[[TABLE]]\n';
      text += line;
      tablePlaceholders.push({ start: offset(start), end: offset(start + utf16Len(line) - 1), table: b.table });
      continue;
    }
    const start = utf16Len(text);
    const line = b.text + '\n';
    text += line;
    const end = start + utf16Len(line) - 1; // exclude trailing \n
    if (b.style === 'BULLET') {
      if (curBulletStart === null) curBulletStart = start;
    } else {
      if (curBulletStart !== null) { bulletRanges.push({ start: offset(curBulletStart), end: offset(start) }); curBulletStart = null; }
      if (b.style === 'H1' || b.style === 'H2' || b.style === 'H3') {
        styledRanges.push({ start: offset(start), end: offset(end), style: b.style });
      }
    }
  }
  if (curBulletStart !== null) bulletRanges.push({ start: offset(curBulletStart), end: offset(utf16Len(text)) });

  // 2. Insert all the plain text in one shot.
  await batchUpdate(token, docId, [{ insertText: { location: { index: insertAt }, text } }]);

  // 3. Apply heading styles + bullet lists — offsets from step 1 are still valid since nothing
  //    before them has shifted.
  const styleReqs = [];
  for (const r of styledRanges) {
    const named = r.style === 'H1' ? 'HEADING_1' : r.style === 'H2' ? 'HEADING_2' : 'HEADING_3';
    styleReqs.push({ updateParagraphStyle: { range: { startIndex: r.start, endIndex: r.end }, paragraphStyle: { namedStyleType: named }, fields: 'namedStyleType' } });
  }
  for (const r of bulletRanges) {
    styleReqs.push({ createParagraphBullets: { range: { startIndex: r.start, endIndex: r.end }, bulletPreset: 'BULLET_DISC_CIRCLE_SQUARE' } });
  }
  if (styleReqs.length) await batchUpdate(token, docId, styleReqs);

  // 4. Replace each table placeholder with a real table, processing in DESCENDING start-index
  //    order so earlier replacements don't shift the indices of placeholders still to come.
  tablePlaceholders.sort((a, b) => b.start - a.start);
  for (const ph of tablePlaceholders) {
    const spec = ph.table;
    const rows = spec.rows.length + 1; // +1 for the header row
    const cols = spec.header.length;

    // Clear the placeholder text, then insert the table at that same index.
    await batchUpdate(token, docId, [{ deleteContentRange: { range: { startIndex: ph.start, endIndex: ph.end } } }]);
    await batchUpdate(token, docId, [{ insertTable: { location: { index: ph.start }, rows, columns: cols } }]);

    // GOTCHA: insertTable can land the table's real startIndex one position *after* the
    // requested location — Docs inserts an empty paragraph immediately before the table. Matching
    // on exact index therefore fails intermittently; re-fetch and match with a small tolerance
    // range instead.
    const freshDoc = await getDocument(token, docId);
    const tableEl = freshDoc.body.content.find(e => e.table && e.startIndex >= ph.start && e.startIndex <= ph.start + 2);
    if (!tableEl) {
      const found = freshDoc.body.content.filter(e => e.table).map(e => e.startIndex).join(', ');
      throw new Error(`Could not locate inserted table near index ${ph.start}. Tables found at: ${found}`);
    }
    const table = tableEl.table;
    const tableStart = tableEl.startIndex;

    // Fill cells — descending index order again, so inserts don't invalidate later ones.
    const allRows = [spec.header, ...spec.rows];
    const cellFillReqs = [];
    for (let r = 0; r < table.tableRows.length; r++) {
      const cells = table.tableRows[r].tableCells;
      for (let c = 0; c < cells.length; c++) {
        const cellStart = cells[c].content[0].startIndex;
        const val = (allRows[r] && allRows[r][c]) || '';
        if (val) cellFillReqs.push({ insertText: { location: { index: cellStart }, text: val } });
      }
    }
    cellFillReqs.sort((a, b) => b.insertText.location.index - a.insertText.location.index);
    if (cellFillReqs.length) await batchUpdate(token, docId, cellFillReqs);

    // Bold the header row — re-fetch again since the cell fills shifted indices.
    const refreshedDoc = await getDocument(token, docId);
    const refreshedTableEl = refreshedDoc.body.content.find(e => e.table && e.startIndex === tableStart);
    const headerCells = refreshedTableEl.table.tableRows[0].tableCells;
    const boldReqs = headerCells.map(cell => {
      const p = cell.content[0];
      const s = p.startIndex, e = p.endIndex - 1;
      if (s >= e) return null;
      return { updateTextStyle: { range: { startIndex: s, endIndex: e }, textStyle: { bold: true }, fields: 'bold' } };
    }).filter(Boolean);
    if (boldReqs.length) await batchUpdate(token, docId, boldReqs);
  }
}

module.exports = { getAccessToken, getDocument, batchUpdate, buildFormattedDoc };

// ── Illustrative example ────────────────────────────────────────────────────
// Run directly (`node docs-format-example.js`, after setting DOC_ID to a real, ideally empty
// doc) to see it build headings, bullets, and a small table in one pass.
if (require.main === module) {
  const blocks = [
    { style: 'H1', text: 'Quarterly Status Report' },
    { style: 'P', text: 'Compiled 2026-07-04.' },

    { style: 'H2', text: 'Highlights' },
    { style: 'BULLET', text: 'Shipped the new onboarding flow.' },
    { style: 'BULLET', text: 'Closed 3 of the 5 open support escalations.' },

    { style: 'H2', text: 'Team Status' },
    { table: {
      header: ['Team', 'Status', 'Notes'],
      rows: [
        ['Platform', 'On track', 'No blockers'],
        ['Growth', 'At risk', 'Waiting on design review'],
      ],
    } },
  ];

  (async () => {
    const token = await getAccessToken();
    await buildFormattedDoc(token, DOC_ID, blocks);
    console.log('DONE. URL: https://docs.google.com/document/d/' + DOC_ID + '/edit');
  })().catch(e => { console.error(e); process.exit(1); });
}
