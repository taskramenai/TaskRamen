#!/usr/bin/env node
// refresh.mjs — stateless OAuth token refresh. Emits new credentials; stores
// nothing. The caller (Claude) holds the refresh_token and stores the result.
//
// Usage:
//   node refresh.mjs --token-endpoint URL --client-id ID
//        (--refresh-token-env VAR | --refresh-token VALUE)
//        [--scope "a b"] [--resource URL] [--client-secret-env VAR]
//
// Prefer --refresh-token-env (and --client-secret-env): a value passed on argv is
// visible via /proc/<pid>/cmdline and shell history. --refresh-token is offered
// for convenience only.
//
// Emits {"event":"credentials", ...}. refresh_token is the rotated one if the
// server returned a new value, otherwise the one you passed in.
// Exit: 0 ok · 1 error.

import { args, emit, fail, refresh } from './common.mjs';

const a = args(process.argv.slice(2));
const tokenEndpoint = a['token-endpoint'];
const clientId = a['client-id'];
const refreshToken = a['refresh-token-env'] ? process.env[a['refresh-token-env']] : a['refresh-token'];
if (!tokenEndpoint || !clientId || !refreshToken) {
  fail(1, 'USAGE', 'refresh needs --token-endpoint, --client-id and (--refresh-token-env VAR | --refresh-token VALUE)');
}
const clientSecret = a['client-secret-env'] ? process.env[a['client-secret-env']] : undefined;
const scopes = a.scope ? String(a.scope).split(/\s+/).filter(Boolean) : undefined;

try {
  const tok = await refresh({ tokenEndpoint, refreshToken, clientId, clientSecret, scopes, resource: a.resource });
  if (!tok.access_token) fail(1, 'NO_ACCESS_TOKEN', 'refresh response had no access_token');
  emit({
    event: 'credentials',
    access_token: tok.access_token,
    refresh_token: tok.refresh_token || refreshToken, // keep the old one if not rotated
    expires_in: tok.expires_in ?? null,
    token_type: tok.token_type || 'Bearer',
    token_endpoint: tokenEndpoint,
    client_id: clientId,
    scopes: scopes || (tok.scope ? tok.scope.split(' ') : []),
    resource: a.resource || null,
  });
} catch (e) {
  fail(1, 'REFRESH_FAILED', e.message);
}
