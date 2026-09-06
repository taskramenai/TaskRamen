#!/usr/bin/env node
// connectdcr.mjs — DCR + random Cloudflare tunnel sign-in (keyring daemon).
//
// PROBES the server for Dynamic Client Registration first and errors (exit 2) if
// it is NOT DCR-capable. Otherwise: stands up an ephemeral mailbox + a verified
// random trycloudflare tunnel, registers a throwaway public client on the live
// tunnel redirect URI, surfaces the authorization URL for the user to click,
// catches the callback, exchanges the code, and hands off the credentials.
//
// Credentials are ALWAYS delivered via the kernel keyring — never stdout, never a
// file. There is NO stdout credential mode: a long-lived refresh_token must never
// be at risk of landing in a detached stdout or a log. If no usable keyring is
// present (keyutils/keyctl missing, or add_key blocked by seccomp/quota), the
// script emits a clear NO_KEYRING / KEYRING_REQUIRED error and STOPS — it does not
// fall back to printing the token.
//
// Modes:
//   • --check           — probe only: emit dcr_ok (non-secret) or NOT_DCR. No
//                         keyring needed; nothing secret is printed.
//   • --keyring <desc>  — run as a background daemon: publish the auth_url on a
//                         loopback long-poll endpoint (GET /authurl) and write the
//                         credentials JSON into the kernel keyring as a `user` key
//                         under <desc>. Progress goes to stderr.
//
// Usage:
//   node connectdcr.mjs <mcp-url> --keyring <desc> [--scope "a b"]
//                       [--keyring-ring @s] [--keyring-timeout SEC]
//                       [--cloudflared PATH] [--port N] [--timeout-ms N]
//   node connectdcr.mjs <mcp-url> --check        # DCR-capability probe only
//
// stdout events (one JSON object per line): only NON-SECRET control events are ever
// printed — {"event":"status"|"dcr_ok"|"error", ...}. The auth_url is served on
// http://127.0.0.1:<port>/authurl (long-poll) and the credentials go to the
// keyring; neither is ever written to stdout or a file.
//
// Exit codes: 0 ok · 2 NOT_DCR · 1 other error (incl. NO_KEYRING / KEYRING_REQUIRED).

import {
  args, emit, fail, discover, registerClient, pkce, mkState,
  buildAuthUrl, exchange, startMailbox, startVerifiedTunnel,
  keyctlAvailable, keyringUsable, keyringStore,
} from './common.mjs';

const a = args(process.argv.slice(2));
const mcp = a._[0];
if (!mcp) fail(1, 'USAGE', 'usage: connectdcr <mcp-url> --keyring <desc> [--scope "a b"] [--cloudflared PATH] [--port N] [--timeout-ms N]  |  connectdcr <mcp-url> --check');

const log = (message) => emit({ event: 'status', message });
const errlog = (message) => process.stderr.write(`[connectdcr] ${message}\n`);

let tunnel = null;
let mailbox = null;
let cleanedUp = false;

function cleanup() {
  if (cleanedUp) return;
  cleanedUp = true;
  try { tunnel?.close(); } catch { /* noop */ }
  try { mailbox?.close(); } catch { /* noop */ }
}

// `finally` does NOT run on a signal, so handle Ctrl-C / kill explicitly —
// otherwise the cloudflared child would be orphaned and the tunnel left up.
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => { cleanup(); process.exit(sig === 'SIGINT' ? 130 : 143); });
}

function resolveScopes(meta) {
  return a.scope ? String(a.scope).split(/\s+/).filter(Boolean) : meta.scopes;
}

function credentialsPayload(tok, { meta, clientId, scopes }) {
  return {
    event: 'credentials',
    access_token: tok.access_token,
    refresh_token: tok.refresh_token || null,
    expires_in: tok.expires_in ?? null,
    token_type: tok.token_type || 'Bearer',
    token_endpoint: meta.token_endpoint,
    client_id: clientId,
    scopes,
    resource: meta.resource,
  };
}

// ---- --check: DCR-capability probe only (no tunnel, no secrets) ----
async function runCheck() {
  log('discovering metadata + probing for DCR');
  const meta = await discover(mcp);
  if (!meta.registration_endpoint) {
    fail(2, 'NOT_DCR', `no registration_endpoint at issuer ${meta.issuer} — not DCR-capable; use connectlocalhost instead`);
  }
  emit({ event: 'dcr_ok', issuer: meta.issuer, registration_endpoint: meta.registration_endpoint });
}

// ---- daemon mode: auth_url over loopback /authurl, credentials into keyring ----
async function runDaemon() {
  const keyDesc = String(a.keyring);
  // Default to the SESSION keyring (@s). The harvester (a separate shell, after this
  // daemon exits) must be able to READ the key — and keyutils gates payload reads on
  // *possession*, not uid. A new key defaults to `possessor: read, user: view` (view
  // ≠ read), so a same-uid process that does not POSSESS the key gets view-only and
  // cannot read the payload. The harvesting shell does not possess @u keys, so @u
  // silently fails at read time (verified on a real VM). It DOES possess @s, because
  // the daemon and the shell share one session keyring — so @s works, and the key
  // survives the daemon's exit because it lives in the shared keyring, not the
  // process. Required corollary: launch the daemon WITHOUT setsid (a new session
  // would break the shared-@s possession). See connectorskill.md #2.
  const keyRing = a['keyring-ring'] || '@s';
  const keyTimeout = Number(a['keyring-timeout']) || 900;
  const port = Number(a.port) || 8765;

  // Fail fast if the keyring sink is unusable — BEFORE the user approves — with a
  // REAL write/unlink round-trip. Catches a missing binary, a seccomp-blocked
  // add_key, or an exhausted quota, so a freshly-minted token is never lost to a
  // sink we could have known was dead. There is no stdout fallback: we stop with a
  // clear error rather than risk printing the token.
  if (!keyctlAvailable()) {
    fail(1, 'NO_KEYRING', `keyctl (keyutils) is not installed — the credentials can only be delivered via the kernel keyring. Install the keyutils package, then re-run. (No stdout fallback: the token is never printed.)`);
  }
  if (!keyringUsable(keyRing)) {
    fail(1, 'NO_KEYRING', `kernel keyring ${keyRing} is present but cannot hold a key (add_key blocked by seccomp, or the per-uid key quota is exhausted) — relax the container seccomp profile (it must permit add_key/keyctl) or clear the quota, then re-run. (No stdout fallback: the token is never printed.)`);
  }

  const { verifier, challenge } = pkce();
  const state = mkState();
  mailbox = await startMailbox({ expectedState: state, timeoutMs: Number(a['timeout-ms']) || undefined, port });
  errlog(`daemon pid ${process.pid}; mailbox + /authurl on 127.0.0.1:${mailbox.port}`);

  let meta, clientId, scopes, redirectUri;
  try {
    errlog('discovering metadata + probing for DCR');
    meta = await discover(mcp);
    if (!meta.registration_endpoint) throw new Error(`NOT_DCR: no registration_endpoint at issuer ${meta.issuer} — use connectlocalhost instead`);
    scopes = resolveScopes(meta);
    errlog('starting verified tunnel');
    tunnel = await startVerifiedTunnel(mailbox.port, mailbox.nonce, {
      bin: a.cloudflared || process.env.CLOUDFLARED_BIN || 'cloudflared',
      log: errlog,
    });
    redirectUri = `${tunnel.url}/callback`;
    errlog(`tunnel live: ${tunnel.url}; registering client (DCR)`);
    const reg = await registerClient(meta.registration_endpoint, redirectUri, scopes);
    clientId = reg.client_id;
    const url = buildAuthUrl({
      authorizationEndpoint: meta.authorization_endpoint,
      clientId, redirectUri, state, challenge, scopes, resource: meta.resource,
    });
    mailbox.setAuthUrl(url);
    errlog('auth_url published on /authurl; awaiting approval');
  } catch (e) {
    // Publish the setup error to /authurl so the foreground fetch sees it, then
    // linger briefly so the in-flight curl can read it before we exit non-zero.
    // The foreground fetch is already connected (the server came up before this
    // block) so setAuthError flushes to it at once; a short linger covers a curl
    // that hasn't reconnected yet. We deliberately don't hold for minutes — that
    // would keep the fixed --port bound and delay a retry (e.g. on NOT_DCR, which
    // is definitive). Silence the (still-armed) callback-timeout rejection to
    // avoid an unhandledRejection if --timeout-ms < the linger.
    mailbox.waitForCode.catch(() => {});
    mailbox.setAuthError(e.message);
    errlog('setup error: ' + e.message);
    await new Promise((r) => setTimeout(r, 15_000));
    throw e;
  }

  const { code } = await mailbox.waitForCode;
  errlog('callback received; exchanging code');
  const tok = await exchange({
    tokenEndpoint: meta.token_endpoint, code, redirectUri, clientId, verifier, resource: meta.resource,
  });

  // The token is now MINTED — write it ONLY to the kernel keyring. We must never
  // fall back to stdout/a file here: in daemon mode stdout is redirected to a log
  // on disk, so emitting the credentials would leak the long-lived refresh_token
  // to disk and break the "no secret on disk" guarantee. If the keyring write
  // fails (it should not — keyringUsable() already proved a write round-trip at
  // startup), fail loudly and discard the token. Nothing secret is logged; the
  // caller simply re-runs the connect flow with a fresh link.
  const credObj = credentialsPayload(tok, { meta, clientId, scopes });
  try {
    const id = keyringStore(keyDesc, JSON.stringify(credObj), { keyring: keyRing, timeoutSec: keyTimeout });
    errlog(`credentials stored: keyring ${keyRing}, key id ${id}, desc "${keyDesc}", expires in ${keyTimeout}s`);
  } catch (e) {
    throw new Error(`KEYRING_STORE_FAILED: the token was minted but could not be written to kernel keyring ${keyRing} (${e.message}). It was DISCARDED — not written to disk or stdout. Re-run the connect flow; if this recurs, check the keyring quota with 'keyctl show ${keyRing}'.`);
  }
}

// Credentials are keyring-only. A real (non-probe) run REQUIRES --keyring; there is
// no stdout credential mode to fall back to.
if (!a.check && !a.keyring) {
  fail(1, 'KEYRING_REQUIRED', 'stdout credential mode has been removed — pass --keyring <desc> to deliver credentials via the kernel keyring (needs keyutils/keyctl). Install keyutils if it is missing. Use --check for a DCR-capability probe.');
}

try {
  if (a.check) await runCheck();
  else await runDaemon();
} catch (e) {
  // Both paths log to stderr and never print the token; preserve the NOT_DCR
  // signal (exit 2). cleanup() only ever SIGTERMs this daemon's own cloudflared
  // child by PID (no pkill, no process-group kill), so a crash or timeout here can
  // never signal or kill the Telegram poller or any sibling. The flow's real
  // protection against the earlier collateral-kill is that it never blocks the main
  // session (backgrounded; the turn ends in seconds), so the frozen-agent watchdog
  // never fires — NOT setsid, which is deliberately avoided here (it would break the
  // shared-@s possession the harvester relies on). See connectorskill.md #2.
  errlog('error: ' + e.message);
  process.exitCode = /^NOT_DCR/.test(e.message) ? 2 : 1;
} finally {
  cleanup();
}
