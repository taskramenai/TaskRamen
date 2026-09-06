// TaskRamen.ai
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

/**
 * Generic Google Slides example — creates a presentation with styled slides via batchUpdate.
 * Copy this as a starting point for any new slides project.
 *
 * Usage:
 *   1. Set PRESENTATION_ID (create via the Slides REST API first)
 *   2. Define your slides data
 *   3. Run: node slides-example.js
 */

const { google } = require('googleapis');
const fs = require('fs');

const PRESENTATION_ID = 'YOUR_PRESENTATION_ID_HERE';

// ── Auth ──────────────────────────────────────────────────────────────────────
// Credentials come from .env (SERVICE_GOOGLE_WORKSPACE_RW_* — see CLAUDE.md "Google Workspace").
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

// ── Helpers ───────────────────────────────────────────────────────────────────
const rgb = (r, g, b) => ({ red: r / 255, green: g / 255, blue: b / 255 });

async function batchUpdate(requests) {
  return (await slides.presentations.batchUpdate({
    presentationId: PRESENTATION_ID,
    requestBody: { requests },
  })).data;
}

function makeTextBox(objectId, pageObjectId, x, y, width, height) {
  return {
    createShape: {
      objectId,
      shapeType: 'TEXT_BOX',
      elementProperties: {
        pageObjectId,
        size: { width: { magnitude: width, unit: 'PT' }, height: { magnitude: height, unit: 'PT' } },
        transform: { scaleX: 1, scaleY: 1, translateX: x, translateY: y, unit: 'PT' },
      },
    },
  };
}

function styleText(objectId, startIndex, endIndex, { bold, fontSize, color, fontFamily } = {}) {
  const style = {};
  const fields = [];
  if (bold !== undefined)    { style.bold = bold; fields.push('bold'); }
  if (fontSize !== undefined) { style.fontSize = { magnitude: fontSize, unit: 'PT' }; fields.push('fontSize'); }
  if (color !== undefined)    { style.foregroundColor = { opaqueColor: { rgbColor: color } }; fields.push('foregroundColor'); }
  if (fontFamily !== undefined) { style.fontFamily = fontFamily; fields.push('fontFamily'); }
  return { updateTextStyle: { objectId, textRange: { type: 'FIXED_RANGE', startIndex, endIndex }, style, fields: fields.join(',') } };
}

function setSlideBackground(slideId, color) {
  return {
    updatePageProperties: {
      objectId: slideId,
      pageProperties: { pageBackgroundFill: { solidFill: { color: { rgbColor: color } } } },
      fields: 'pageBackgroundFill.solidFill.color',
    },
  };
}

function setShapeFill(objectId, color) {
  return {
    updateShapeProperties: {
      objectId,
      shapeProperties: { shapeBackgroundFill: { solidFill: { color: { rgbColor: color } } } },
      fields: 'shapeBackgroundFill.solidFill.color',
    },
  };
}

// ── Main ──────────────────────────────────────────────────────────────────────
(async () => {
  // Get existing presentation to find the default slide ID
  const pres = await slides.presentations.get({ presentationId: PRESENTATION_ID });
  const defaultSlideId = pres.data.slides[0].objectId; // usually 'p'

  const requests = [];

  // ── Slide 1 (default slide) ──
  const S1 = defaultSlideId;
  requests.push(setSlideBackground(S1, rgb(27, 94, 32)));          // dark green bg
  requests.push(makeTextBox(`${S1}_title`, S1, 30, 80, 660, 80));
  requests.push({ insertText: { objectId: `${S1}_title`, insertionIndex: 0, text: 'Slide Title Here' } });
  requests.push(styleText(`${S1}_title`, 0, 16, { bold: true, fontSize: 44, color: rgb(255,255,255), fontFamily: 'Montserrat' }));

  requests.push(makeTextBox(`${S1}_sub`, S1, 30, 180, 660, 50));
  requests.push({ insertText: { objectId: `${S1}_sub`, insertionIndex: 0, text: 'Subtitle or description' } });
  requests.push(styleText(`${S1}_sub`, 0, 23, { fontSize: 20, color: rgb(200,230,201) }));

  // ── Slide 2 ──
  requests.push({ createSlide: { objectId: 'slide2', slideLayoutReference: { predefinedLayout: 'BLANK' } } });
  requests.push(setSlideBackground('slide2', rgb(255, 255, 255)));
  requests.push(makeTextBox('slide2_title', 'slide2', 30, 40, 660, 60));
  requests.push({ insertText: { objectId: 'slide2_title', insertionIndex: 0, text: 'Second Slide' } });
  requests.push(styleText('slide2_title', 0, 12, { bold: true, fontSize: 32, color: rgb(27,94,32) }));

  requests.push(makeTextBox('slide2_body', 'slide2', 30, 120, 660, 300));
  requests.push({ insertText: { objectId: 'slide2_body', insertionIndex: 0, text: 'Body content goes here.\nAdd more lines as needed.' } });
  requests.push(styleText('slide2_body', 0, 46, { fontSize: 16, color: rgb(33,33,33) }));

  // Send all in one call
  await batchUpdate(requests);
  console.log('Done. Presentation ID:', PRESENTATION_ID);
})();
