# Architecture & internals

How these scripts work, for anyone who wants to dive deeper. The README covers what the
repo is and how to use it; this file covers the design and the per-script internals.
Operational, per-service flow detail lives in `connectorskill.md` (method **#2** DCR,
**#4** OAuth-localhost) and `storingsecrets.md` (credential storage).

## Design rules

1. **No hardcoded site knowledge.** There is no provider table, no per-service recipe, no
   special-casing. Endpoints come from **standard RFC discovery** (RFC 9728 → RFC 8414) or
   are passed in as flags. *Claude supplies the intelligence* (which service, which
   endpoints/scopes/client, which mode).
2. **No secret storage on disk.** The scripts never write secrets to disk. They **emit**
   results as JSON events on stdout; **the caller (Claude) stores** tokens/keys securely
   (e.g. `.env`, chmod 600). A confidential client secret, if needed, is read transiently
   from an env var — never argv, never persisted. (`connectdcr.mjs` hands credentials off
   **only** via the **kernel keyring** (`--keyring`) — kernel memory, access-controlled,
   auto-expiring — never stdout and never a disk file; it has no stdout credential mode and
   stops with a clear error if no keyring is usable.)
3. **One job each, stateless.** State between the two `connectlocalhost` calls is carried by
   the caller, not the script.

## Scripts

### `connectdcr.mjs` — DCR with a random tunnel

Single invocation. Probes the MCP server for Dynamic Client Registration and **errors
(exit 2) if it is not DCR-capable**; otherwise runs the full sign-in over a verified random
`trycloudflare` tunnel and emits the credentials.

```
node connectdcr.mjs <mcp-url> --keyring <desc> [--scope "a b"]
                    [--keyring-ring @s] [--keyring-timeout SEC]
                    [--cloudflared PATH] [--port N] [--timeout-ms N]
node connectdcr.mjs <mcp-url> --check        # DCR-capability probe only
```
- Credentials are delivered **only via the kernel keyring** — there is **no stdout
  credential mode**. A real sign-in **requires `--keyring`**; without it the script stops
  with `KEYRING_REQUIRED`. This is deliberate: a long-lived `refresh_token` must never be at
  risk of landing in a detached stdout or a log.
- `--check` — probe only; emit `dcr_ok` or `NOT_DCR` and exit. No keyring needed; nothing
  secret is printed.
- Needs the **`cloudflared`** binary on `PATH` (or `--cloudflared` / `CLOUDFLARED_BIN`).
- **`--keyring <desc>` (daemon mode)** — run as a background daemon: serve the auth URL on a
  loopback long-poll endpoint `GET /authurl` (and `/status`), and write the final
  credentials JSON into the kernel keyring (`user` key `<desc>`, default ring `@s` — the
  **session** keyring, which the daemon and the later harvesting shell share, so the shell
  *possesses* the key and can read its payload; `@u` does **not** work here — keyutils gates
  payload reads on possession, not uid, and a separate process gets only `view`, not `read`;
  expiry `--keyring-timeout`, default 900s). Progress goes to stderr; **no secret is
  printed.** Needs a usable keyring (`keyctl` from keyutils, and a seccomp profile that
  permits `add_key`); the daemon **fails fast with `NO_KEYRING`** at startup (a real
  write/unlink round-trip) if it can't store — with a clear message to install keyutils or
  relax seccomp, and **never** a fallback to printing the token. So the user is never asked
  to approve a flow whose token couldn't be saved. The caller fetches the URL with
  `curl …/authurl`, ends its turn during approval, and harvests with `keyctl print` on
  "done". See `connectorskill.md` #2.
- **Lifetime:** the loopback mailbox + tunnel live only until the callback completes the
  flow or `--timeout-ms` (default 11 min) elapses — then both are torn down. Teardown also
  runs on `SIGINT`/`SIGTERM`, so cloudflared is never left orphaned. Launch the daemon with
  a plain `&` in the caller's session (**not** `setsid` — a new session would break the
  shared-`@s` possession the harvester needs); `cleanup()` only SIGTERMs its own cloudflared
  child by PID, and the non-blocking launch keeps the main session responsive, so a timeout
  or crash can never take down a sibling process.

stdout events: only the **non-secret** control events are ever printed — `status` ·
`dcr_ok` (with `--check`) · `error`. Exit: `0` ok · `2` NOT_DCR · `1` other (incl.
`NO_KEYRING` / `KEYRING_REQUIRED`). The auth URL is served on `/authurl` and credentials go
to the keyring; **stdout never carries the auth_url or credentials.**

### `connectlocalhost.mjs` — OAuth with localhost (two modes)

No DCR, no tunnel, no listener. The user opens the URL on their own device; after Allow the
browser lands on `http://localhost:<port>/callback?...` and shows a "can't reach" error
(expected) — they copy the full URL back.

```
# 1) generate the URL + a session blob the caller keeps
node connectlocalhost.mjs start --authorize-endpoint URL --token-endpoint URL \
     --client-id ID [--scope "a b"] [--port 8080] [--resource URL] [--extra k=v ...]

# 2) hand back the pasted localhost URL + that session blob to exchange
node connectlocalhost.mjs finish --pasted "<localhost-callback-url>" \
     --session '<session-json>' [--client-secret-env VAR]
```
`start` emits `auth_url` + `session`; `finish` emits `credentials`. The caller relays the
URL, holds the `session`, and stores the `credentials`.

### `refresh.mjs` — stateless token refresh

Refresh an access token without re-signing-in. Stores nothing; emits new credentials.

```
node refresh.mjs --token-endpoint URL --client-id ID \
     (--refresh-token-env VAR | --refresh-token VALUE) \
     [--scope "a b"] [--resource URL] [--client-secret-env VAR]
```
Prefer `--refresh-token-env` (and `--client-secret-env`) — an argv value is visible in
`/proc/<pid>/cmdline`. Emits `credentials`; the `refresh_token` is the rotated one if the
server returned a new value, else the one you passed in.

## How Claude drives them

1. Decide the method (see `connectorskill.md`): DCR → `connectdcr`; OAuth-localhost →
   `connectlocalhost` (after the user creates an OAuth app and you have the `--client-id` /
   endpoints).
2. Run the script, read the JSON events, relay `auth_url` to the user.
3. On `credentials`, **store them yourself** in `.env` (`chmod 600`) per the naming
   conventions in **`storingsecrets.md`**. Refresh later is a plain `token_endpoint` POST
   (`grant_type=refresh_token`) using the stored `refresh_token` + `client_id`.

## cloudflared

`connectdcr` shells out to **cloudflared** (Cloudflare Tunnel), which is **not bundled** —
install it separately. cloudflared is **Apache-2.0** licensed, so it *can* be
redistributed/bundled with attribution (ship its `LICENSE`/`NOTICE`), but these scripts
expect it at runtime to avoid vendoring per-platform binaries. Note the
**`trycloudflare.com` quick-tunnel service** is separate from the binary license — it's
governed by Cloudflare's ToS, has no SLA, and is intended for ephemeral/testing use.

## Security model

- Tokens and any client secret appear **only** in the emitted `credentials` event /
  transiently in memory — nothing is written to disk by these scripts.
- The authorization URL is safe to relay (public `client_id` + PKCE S256 challenge +
  `state`; no secret).
- `state` is validated before any code is exchanged (CSRF / mix-up guard).
- The caller must treat the `credentials` event as sensitive and store it `chmod 600` per
  **`storingsecrets.md`**.
