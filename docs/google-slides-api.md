# Google Slides API Reference

Create the presentation, then add all content with `batchUpdate` (a bare create makes an empty shell).

Credentials live in `.env` under the `SERVICE_GOOGLE_WORKSPACE_RW_` prefix (see CLAUDE.md "Google Workspace").

## Template lookup (before building from scratch)

There is a single template pool shared with PowerPoint — no separate Slides
template folder. Since a brand-new Slides deck is always built as a `.pptx`
first (see "Build new presentations as PowerPoint first, then upload" below),
template lookup is identical to the PowerPoint skill's own lookup step: read
`skills/powerpoint/templates/index.json` and match its entries against the
request by topic/style (tags/description) — rather than assuming a fixed list
of templates or hardcoding any template name. See
`skills/powerpoint/SKILL.md` → "Template lookup (before building from
scratch)" for the full convention and `skills/powerpoint/templates/README.md`
for the index format. If there's a plausible match, use that entry's file as
the starting `.pptx` instead of a blank deck. If nothing matches (including
when the index is empty), fall back to blank.

If the user hasn't supplied a template and the request would benefit from
consistent branding going forward, mention once that they can send an
existing PowerPoint or Google Slides presentation for TaskRamen to use as a
template — it gets saved into `skills/powerpoint/templates/` (the same pool
used here) for reuse on future presentations. Don't repeat this prompt every
time; a one-off mention is enough.

## Turning a sent presentation into a template

Same trigger and procedure as PowerPoint — **only when the user explicitly
asks** to use/save a sent presentation as a template (not merely because they
sent one). See `skills/powerpoint/SKILL.md` → "Turning a sent presentation
into a template" for the full trigger condition and steps (download/extract,
convert to `.pptx` via LibreOffice if needed, render thumbnails and inspect
visually before naming/tagging, **strip deck-specific content down to
placeholder text/images while keeping recurring brand assets like a logo**,
save into `skills/powerpoint/templates/`, add an `index.json` entry, confirm
with the user) — it applies unchanged whether the presentation was sent for
Slides or PowerPoint use, since both share the one template pool.

## Build new presentations as PowerPoint first, then upload

For a **brand-new** Google Slides presentation built from scratch, don't
construct it directly via `batchUpdate` calls — build it first as a `.pptx`
using `skills/powerpoint/SKILL.md` (python-pptx is far easier to iterate on
programmatically than the Slides API's per-shape `batchUpdate` requests; if a
template matched, that skill's "Branded decks" section has the concrete
slide-number → layout table for what's actually in
`skills/powerpoint/templates/` — duplicate the matching example slide rather
than adding a blank layout), run its thumbnail QA step there, then upload the
finished `.pptx` to Drive with a `mimeType` conversion to Google Slides (see
"Create by uploading a PowerPoint" below). This produces a real, editable
Slides file without ever hand-building shapes through `batchUpdate`.

`batchUpdate` (the reference below) is still the right tool for **editing an
existing** Slides presentation in place — small text/style tweaks, adding a
slide to a deck the user is already collaborating on, etc. Reserve the
build-from-scratch case for the PowerPoint-first path.

## Auth setup

```js
const { google } = require('googleapis');
const fs = require('fs');
const envTxt = fs.readFileSync((process.env.CLAUDE_HOME || process.env.HOME) + '/.env', 'utf8');
const envGet = k => { const m = envTxt.match(new RegExp('^' + k + '=\\s*([^#\\r\\n]*?)\\s*(?:#.*)?$', 'm')); return m ? m[1].trim().replace(/^["']|["']$/g, '') : (process.env[k] || ''); };
const creds = {
  client_id: envGet('SERVICE_GOOGLE_WORKSPACE_RW_CLIENT_ID'),
  client_secret: envGet('SERVICE_GOOGLE_WORKSPACE_RW_CLIENT_SECRET'),
  refresh_token: envGet('SERVICE_GOOGLE_WORKSPACE_RW_REFRESH_TOKEN'),
  token: envGet('SERVICE_GOOGLE_WORKSPACE_RW_ACCESS_TOKEN'),
  scopes: envGet('SERVICE_GOOGLE_WORKSPACE_RW_SCOPES').split(/\s+/).filter(Boolean),
};
const auth = new google.auth.OAuth2(creds.client_id, creds.client_secret);
auth.setCredentials({ refresh_token: creds.refresh_token, access_token: creds.token, scope: creds.scopes.join(' ') });
const slides = google.slides({ version: 'v1', auth });
```

## batchUpdate wrapper
```js
async function batchUpdate(requests) {
  return (await slides.presentations.batchUpdate({ presentationId: ID, requestBody: { requests } })).data;
}
```

## Key request types
```js
// Add blank slide
{ createSlide: { objectId: 'slide2', slideLayoutReference: { predefinedLayout: 'BLANK' } } }

// Add text box
{ createShape: { objectId: 'id', shapeType: 'TEXT_BOX', elementProperties: {
  pageObjectId: 'slide1',
  size: { width: { magnitude: 500, unit: 'PT' }, height: { magnitude: 60, unit: 'PT' } },
  transform: { scaleX: 1, scaleY: 1, translateX: 30, translateY: 40, unit: 'PT' }
}}}

// Insert text
{ insertText: { objectId: 'id', insertionIndex: 0, text: 'Hello' } }

// Style text
{ updateTextStyle: { objectId: 'id',
  textRange: { type: 'FIXED_RANGE', startIndex: 0, endIndex: 5 },
  style: { bold: true, fontSize: { magnitude: 36, unit: 'PT' },
    foregroundColor: { opaqueColor: { rgbColor: { red: 1, green: 1, blue: 1 } } }, fontFamily: 'Montserrat' },
  fields: 'bold,fontSize,foregroundColor,fontFamily' }}

// Slide background
{ updatePageProperties: { objectId: 'slide1',
  pageProperties: { pageBackgroundFill: { solidFill: { color: { rgbColor: { red: 0.1, green: 0.37, blue: 0.13 } } } } },
  fields: 'pageBackgroundFill.solidFill.color' }}

// Shape fill
{ updateShapeProperties: { objectId: 'id',
  shapeProperties: { shapeBackgroundFill: { solidFill: { color: { rgbColor: { red: 0.2, green: 0.49, blue: 0.2 } } } } },
  fields: 'shapeBackgroundFill.solidFill.color' }}
```

```js
const rgb = (r, g, b) => ({ red: r/255, green: g/255, blue: b/255 });
```

Object IDs must be unique — use `slideId_elementName` convention.

## Create by uploading a PowerPoint (preferred for brand-new decks)

Per "Build new presentations as PowerPoint first, then upload" above: once
the `.pptx` is built and QA'd via `skills/powerpoint/SKILL.md`, upload it to
Drive with a `mimeType` conversion request so Drive converts it to a native
Google Slides file in one call. This uses the same Drive REST base and auth
pattern as `docs/google-rest-api.md` → "Drive" (`httpsRequest`/`envGet`
helpers defined there); multipart upload is the one addition needed for a
file body:

```js
// Reuses envGet/httpsRequest from docs/google-rest-api.md's Auth setup.
const fs = require('fs');
const https = require('https');

async function uploadPptxAsSlides(token, filePath, name) {
  const boundary = 'taskramen-boundary-' + Date.now();
  const metadata = JSON.stringify({
    name,
    mimeType: 'application/vnd.google-apps.presentation', // target: native Slides
  });
  const fileBytes = fs.readFileSync(filePath);
  const body = Buffer.concat([
    Buffer.from(
      `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${metadata}\r\n` +
      `--${boundary}\r\nContent-Type: application/vnd.openxmlformats-officedocument.presentationml.presentation\r\n\r\n`
    ),
    fileBytes,
    Buffer.from(`\r\n--${boundary}--`),
  ]);

  return new Promise((resolve, reject) => {
    const req = https.request({
      method: 'POST',
      hostname: 'www.googleapis.com',
      path: '/upload/drive/v3/files?uploadType=multipart&fields=id,name,webViewLink',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': `multipart/related; boundary=${boundary}`,
        'Content-Length': body.length,
      },
    }, res => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => { try { resolve(JSON.parse(data)); } catch { resolve(data); } });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

// Usage: const file = await uploadPptxAsSlides(token, 'projects/<name>/deck.pptx', 'Quarterly Review');
// file.id is the new presentationId; file.webViewLink opens it in Slides.
// Then share it per docs/google-rest-api.md → "Share a file" (default: <MY_EMAIL>).
```

- The `mimeType: 'application/vnd.google-apps.presentation'` on the metadata
  part is what tells Drive to *convert* the upload into a native Slides file
  (not just store the raw `.pptx` blob) — this is the same conversion
  mechanism Drive uses for any Office→Google-native import.
- After upload, the file behaves like any other Slides presentation — edit it
  further with `batchUpdate`, and run the thumbnail QA step below on it same
  as a presentation created directly via the API.
- Share the new file with `<MY_EMAIL>` per `docs/google-rest-api.md` →
  "Share a file" (default sharing behavior in CLAUDE.md "Google Workspace").

### Callout: native PowerPoint charts get rasterized, not preserved

**A native chart object built in the `.pptx` (e.g. python-pptx `add_chart`)
does NOT survive the Drive pptx→Slides conversion as an editable Slides
chart.** Drive's converter rasterizes it into a flat image element instead —
confirmed empirically (2026-07-19: a python-pptx
`XL_CHART_TYPE.COLUMN_CLUSTERED` chart round-tripped
through the upload-as-Slides step above came out the other side as a
`pageElement.image`, not a `pageElement.sheetsChart`) and matches general
PowerPoint→Slides conversion behavior — charts lose their data connection on
conversion and Slides cannot maintain PowerPoint's live chart data model.
Visually the result can be pixel-perfect (this is often an acceptable
outcome for a static deck), but it is a picture: no data table, no series/
color editing, no resizing without quality loss.

**If the user needs a genuinely editable chart in the final Slides doc**,
there is no conversion setting or pptx trick that avoids this — charts must
be added as a **separate follow-up step** after the upload, using the Slides
API's `createSheetsChart` request. This is the only mechanism that produces
a real Slides chart object (editable data table, restylable series), because
Slides charts are always backed by a Google Sheet — there is no
"paste a standalone editable chart" primitive in the Slides API.

**createSheetsChart approach (linked chart, embeds a chart that already
exists in a Sheet):**

1. Create (or reuse) a Google Sheet and write the source data with `values.update`
   (see `docs/google-rest-api.md` → "Sheets").
2. Add a chart to that Sheet via the **Sheets API**, `spreadsheets.batchUpdate`
   with an `addChart` request (`spec.basicChart` for column/bar/line charts;
   set `series[].color` to match brand colors — e.g. `{ red: 0.0, green:
   0.7216, blue: 0.6275 }` for `#00B8A0`). The response's
   `replies[0].addChart.chart.chartId` is the numeric chart ID you need next.
   ```json
   {
     "requests": [{
       "addChart": {
         "chart": {
           "spec": {
             "title": "Chart Title",
             "basicChart": {
               "chartType": "COLUMN",
               "legendPosition": "NO_LEGEND",
               "axis": [{ "position": "BOTTOM_AXIS" }, { "position": "LEFT_AXIS", "title": "Y Label" }],
               "domains": [{ "domain": { "sourceRange": { "sources": [
                 { "sheetId": 0, "startRowIndex": 0, "endRowIndex": 6, "startColumnIndex": 0, "endColumnIndex": 1 }
               ] } } }],
               "series": [{
                 "series": { "sourceRange": { "sources": [
                   { "sheetId": 0, "startRowIndex": 0, "endRowIndex": 6, "startColumnIndex": 1, "endColumnIndex": 2 }
                 ] } },
                 "targetAxis": "LEFT_AXIS",
                 "color": { "red": 0.0, "green": 0.7216, "blue": 0.6275 }
               }],
               "headerCount": 1
             }
           },
           "position": { "overlayPosition": {
             "anchorCell": { "sheetId": 0, "rowIndex": 0, "columnIndex": 3 },
             "widthPixels": 600, "heightPixels": 371
           } }
         }
       }
     }]
   }
   ```
3. **Share the Sheet** with `<MY_EMAIL>` (or whoever needs edit access) —
   required, since a Slides-embedded Sheets chart stays live-linked to its
   source Sheet and needs that Sheet to remain accessible.
4. On the **Slides** presentation, `batchUpdate` a `createSheetsChart`
   request targeting the page/position (optionally preceded by a
   `deleteObject` request to remove an old rasterized image chart first —
   read the element's existing `size`/`transform` via `presentations.get`
   so the new chart lands in the same spot):
   ```json
   {
     "requests": [
       { "deleteObject": { "objectId": "old_image_element_id" } },
       {
         "createSheetsChart": {
           "objectId": "new_chart_id",
           "spreadsheetId": "SPREADSHEET_ID",
           "chartId": 587442099,
           "linkingMode": "LINKED",
           "elementProperties": {
             "pageObjectId": "p4",
             "size": { "width": { "magnitude": 3000000, "unit": "EMU" }, "height": { "magnitude": 3000000, "unit": "EMU" } },
             "transform": { "scaleX": 2.83464, "scaleY": 1.38684, "translateX": 685800, "translateY": 1691640, "unit": "EMU" }
           }
         }
       }
     ]
   }
   ```
   `linkingMode: 'LINKED'` makes it refreshable later (edit the Sheet data,
   then `refreshSheetsChart` on the same `objectId` to sync); use
   `NOT_LINKED_IMAGE` instead if a one-time static snapshot is wanted (but
   then there's no benefit over the rasterized-image outcome you already get
   for free from the pptx upload).
5. Required OAuth scope: Sheets access (`spreadsheets` or
   `spreadsheets.readonly`) in addition to the usual Slides/Drive scopes.

**Bottom line:** build the deck as PowerPoint first (per the section above)
for everything except charts that must stay editable in the final Slides
doc; for those, either accept the rasterized image (fine for a static/
one-off presentation) or do the `createSheetsChart` embed as a deliberate
follow-up step once the deck is already in Slides.

## Always visually verify with the thumbnail API

**When you create a slide, make a major edit to a slide, or the user complains about a slide's visual appearance, ALWAYS render the page to an image and look at it** — check layout (overlap, overflow off the canvas, alignment, spacing), readability (contrast, font size), and overall visual attractiveness. Do not trust that the `batchUpdate` looked right; inspect the actual render and fix any issues, then re-render to confirm.

**Also check for large unused empty space, not just overflow/overlap** — in
two distinct forms: (1) a text block or object stranded in one part of an
otherwise-blank slide (e.g. a two-column block only filling the top third),
and (2) a large dead gap **between** multiple separate elements sharing a
region (e.g. a callout pinned near the top and a caption pinned near the
bottom of the same column, with nothing between them) — each element can
look individually fine while the space between them is still unfinished.
See `skills/powerpoint/SKILL.md` → "QA before delivering" for the full rule
and concrete fixes for both forms (bigger text/spacing, an added visual
element, expanded content, redistributing elements more evenly, or
resizing/repositioning to fill the area proportionally) — it applies the
same way here, with the same exception: a mostly-empty layout can be a
deliberate stylistic choice (quote/title/big-stat slides), so use judgment
rather than forcing every slide to be dense.

For corporate/business-style decks, see `skills/powerpoint/corporate-deck-style.md` for
styling rules (font-size hierarchy, bullets vs prose, source-citation footer
placement, etc.) — these apply the same way to Slides as to PowerPoint.

REST endpoint (returns a short-lived `contentUrl`, valid ~30 min — download it immediately):
```
GET https://slides.googleapis.com/v1/presentations/{presentationId}/pages/{pageObjectId}/thumbnail?thumbnailProperties.thumbnailSize=LARGE
Authorization: Bearer $SERVICE_GOOGLE_WORKSPACE_RW_ACCESS_TOKEN
```
- `thumbnailProperties.thumbnailSize`: `LARGE` (~1600px wide — use this for inspection), `MEDIUM` (~800px), `SMALL` (~200px).
- `thumbnailProperties.mimeType`: `PNG` (default).
- Response: `{ "contentUrl": "...", "width": ..., "height": ... }`. Fetch `contentUrl` to get the PNG bytes, save to the project folder, then open/Read the image to actually look at it.

googleapis (Node) equivalent — get a thumbnail for every page and download each:
```js
// Node 18+ exposes global fetch — no extra dependency needed.
async function renderPage(pageObjectId, outPath) {
  const { data } = await slides.presentations.pages.getThumbnail({
    presentationId: ID,
    pageObjectId,
    'thumbnailProperties.thumbnailSize': 'LARGE',
  });
  const res = await fetch(data.contentUrl);
  if (!res.ok) throw new Error(`thumbnail download failed: ${res.status} ${res.statusText}`);
  const png = Buffer.from(await res.arrayBuffer());
  fs.writeFileSync(outPath, png);
  return outPath; // then view/Read this image and judge the layout
}

// Render all pages after a batchUpdate:
const pres = await slides.presentations.get({ presentationId: ID });
for (const [i, p] of (pres.data.slides || []).entries()) {
  await renderPage(p.objectId, `slide_${i + 1}.png`);
}
```
Requires a read scope (`presentations.readonly`/`presentations` or `drive`/`drive.readonly`) in `SERVICE_GOOGLE_WORKSPACE_RW_SCOPES`; refresh the access token first on a 401 (see CLAUDE.md "Google Workspace").

Working example: `examples/slides-example.js` (generic, copy as starting point)
