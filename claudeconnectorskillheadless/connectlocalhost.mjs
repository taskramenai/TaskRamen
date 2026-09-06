#!/usr/bin/env node
// connectlocalhost.mjs — OAuth-with-localhost sign-in (no DCR, no tunnel, no
// listener). Two stateless modes; the SCRIPT keeps no state between them — the
// caller (Claude) holds the `session` blob from `start` and passes it to `finish`.
// Stores nothing; emits credentials for the caller to store.
//
// All endpoints/scopes/client_id are supplied as args — NO site-specific logic.
//
// Mode 1 — start:
//   node connectlocalhost.mjs start --authorize-endpoint URL --token-endpoint URL
//        --client-id ID [--scope "a b"] [--port 8080] [--resource URL] [--extra k=v ...]
//   emits:
//     {"event":"auth_url","url": ..., "redirect_uri": ...}   RELAY to the user
//     {"event":"session", ...}                               CALLER keeps; pass to finish
//
// Mode 2 — finish:
//   node connectlocalhost.mjs finish --pasted "<localhost-callback-url>"
//        --session '<session-json>' [--client-secret-env VAR]
//   emits:
//     {"event":"credentials", ...}                           CALLER stores
//
// The user opens the auth URL on their OWN device; after Allow the browser lands
// on http://localhost:<port>/callback?... and shows a "can't reach" error (no
// listener) — that is EXPECTED. They copy the full URL and it goes to `finish`.
//
// A confidential client's secret is read from an ENV VAR (never argv), only if
// --client-secret-env is given; it is used transiently and never stored.

import { args, emit, fail, pkce, mkState, buildAuthUrl, exchange, parseCallback } from './common.mjs';

const a = args(process.argv.slice(2));
const mode = a._[0];

if (mode === 'start') {
  const authorizeEndpoint = a['authorize-endpoint'];
  const tokenEndpoint = a['token-endpoint'];
  const clientId = a['client-id'];
  if (!authorizeEndpoint || !tokenEndpoint || !clientId) {
    fail(1, 'USAGE', 'start needs --authorize-endpoint, --token-endpoint and --client-id');
  }
  const port = Number(a.port) || 8080;
  const redirectUri = `http://localhost:${port}/callback`;
  const scopes = a.scope ? String(a.scope).split(/\s+/).filter(Boolean) : [];
  const { verifier, challenge } = pkce();
  const state = mkState();

  const url = buildAuthUrl({
    authorizationEndpoint: authorizeEndpoint, clientId, redirectUri, state, challenge,
    scopes, resource: a.resource, extra: a.extra,
  });

  emit({
    event: 'auth_url', url, redirect_uri: redirectUri,
    note: 'After Allow, the browser lands on a localhost page showing an error — that is expected. Copy the FULL localhost URL and pass it to `finish`.',
  });
  emit({
    event: 'session',
    verifier, state,
    token_endpoint: tokenEndpoint, client_id: clientId, redirect_uri: redirectUri,
    resource: a.resource || null, scopes,
  });
  process.exit(0);
}

if (mode === 'finish') {
  if (!a.pasted || !a.session) fail(1, 'USAGE', "finish needs --pasted \"<url>\" and --session '<json>'");
  let s;
  try { s = JSON.parse(a.session); } catch { fail(1, 'BAD_SESSION', '--session is not valid JSON'); }

  const parsed = parseCallback(a.pasted);
  if (parsed.error) fail(1, 'OAUTH_ERROR', parsed.error + (parsed.error_description ? ': ' + parsed.error_description : ''));
  if (!parsed.code) fail(1, 'NO_CODE', 'no authorization code found in the pasted URL');
  if (parsed.state !== s.state) fail(1, 'STATE_MISMATCH', 'state in the pasted URL does not match the session (possible CSRF)');

  const clientSecret = a['client-secret-env'] ? process.env[a['client-secret-env']] : undefined;

  try {
    const tok = await exchange({
      tokenEndpoint: s.token_endpoint, code: parsed.code, redirectUri: s.redirect_uri,
      clientId: s.client_id, clientSecret, verifier: s.verifier, resource: s.resource || undefined,
    });
    emit({
      event: 'credentials',
      access_token: tok.access_token,
      refresh_token: tok.refresh_token || null,
      expires_in: tok.expires_in ?? null,
      token_type: tok.token_type || 'Bearer',
      token_endpoint: s.token_endpoint,
      client_id: s.client_id,
      scopes: s.scopes || [],
      resource: s.resource || null,
    });
    process.exit(0);
  } catch (e) {
    fail(1, 'EXCHANGE_FAILED', e.message);
  }
}

fail(1, 'USAGE', 'first argument must be `start` or `finish`');
