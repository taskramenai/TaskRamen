#!/usr/bin/env node
// TaskRamen.ai
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)
/**
 * Webhook channel for Claude Code — receive-only system trigger channel.
 *
 * Localhost HTTP server on 127.0.0.1:8788.
 * POST /message — delivers text to the Claude Code session via MCP notification.
 * GET  /health  — returns server status and pending message stats.
 *
 * The only MCP tool is `ack` — internal health tracking, not a reply tool.
 * No reply/edit tools — this channel is receive-only by construction.
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { createServer } from 'http';
import { randomUUID, timingSafeEqual } from 'crypto';

// Load WEBHOOK_CHANNEL_SECRET from .env if not in environment
// (MCP servers are spawned by Claude Code and may not inherit shell env vars)
if (!process.env.WEBHOOK_CHANNEL_SECRET) {
  try {
    const claudeHome = process.env.CLAUDE_HOME || dirname(dirname(fileURLToPath(import.meta.url)));
    const envContent = readFileSync(join(claudeHome, '.env'), 'utf-8');
    const match = envContent.match(/^WEBHOOK_CHANNEL_SECRET=(.+)$/m);
    if (match) {
      let val = match[1].trim();
      val = val.replace(/^(['"])(.*)\1$/, '$2');
      process.env.WEBHOOK_CHANNEL_SECRET = val;
    }
  } catch {}
}

const PORT = parseInt(process.env.WEBHOOK_CHANNEL_PORT || '8788', 10);
const SECRET = process.env.WEBHOOK_CHANNEL_SECRET || '';
const BODY_LIMIT = 10 * 1024; // 10KB
const RATE_LIMIT_WINDOW = 60 * 1000; // 1 minute
const RATE_LIMIT_MAX = 30;
const PENDING_EXPIRY = 30 * 60 * 1000; // 30 minutes

// ── Rate limiter ────────────────────────────────────────────────────────────
const requestTimestamps = [];

function isRateLimited() {
  const now = Date.now();
  // Remove timestamps outside the window
  while (requestTimestamps.length > 0 && requestTimestamps[0] < now - RATE_LIMIT_WINDOW) {
    requestTimestamps.shift();
  }
  if (requestTimestamps.length >= RATE_LIMIT_MAX) return true;
  requestTimestamps.push(now);
  return false;
}

// ── Pending messages ────────────────────────────────────────────────────────
const pending = new Map(); // id -> { text, receivedAt }
let lastAcked = null; // { id, at }
const startTime = Date.now();

function cleanupPending() {
  const now = Date.now();
  for (const [id, entry] of pending) {
    if (now - entry.receivedAt > PENDING_EXPIRY) {
      pending.delete(id);
    }
  }
}

// Cleanup every 5 minutes
setInterval(cleanupPending, 5 * 60 * 1000).unref();

// ── MCP Server ──────────────────────────────────────────────────────────────
const mcp = new Server(
  { name: 'webhook-channel', version: '0.0.1' },
  {
    capabilities: {
      tools: {},
      experimental: {
        'claude/channel': {},
      },
    },
    instructions: [
      'This is a receive-only channel for system triggers and scheduled tasks.',
      'After processing each inbound message, call the ack tool with the message_id from the meta field.',
      'This is internal health tracking, not a reply.',
      'Never reply through this channel — always respond via Telegram.',
    ].join(' '),
  },
);

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'ack',
      description:
        'Acknowledge receipt of a webhook message. Call after processing each inbound message. This is internal health tracking — not a reply mechanism.',
      inputSchema: {
        type: 'object',
        properties: {
          message_id: {
            type: 'string',
            description: 'The message_id from the inbound channel meta field.',
          },
        },
        required: ['message_id'],
      },
    },
  ],
}));

mcp.setRequestHandler(CallToolRequestSchema, async (req) => {
  const args = (req.params.arguments ?? {});
  if (req.params.name === 'ack') {
    const messageId = args.message_id;
    if (messageId && pending.has(messageId)) {
      pending.delete(messageId);
    }
    lastAcked = { id: messageId, at: new Date().toISOString() };
    return { content: [{ type: 'text', text: 'ok' }] };
  }
  return {
    content: [{ type: 'text', text: `unknown tool: ${req.params.name}` }],
    isError: true,
  };
});

// ── HTTP Server ─────────────────────────────────────────────────────────────
function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > BODY_LIMIT) {
        reject(new Error('BODY_TOO_LARGE'));
        req.destroy();
        return;
      }
      data += chunk;
    });
    req.on('end', () => resolve(data));
    req.on('error', reject);
  });
}

const httpServer = createServer(async (req, res) => {
  // ── GET /health ─────────────────────────────────────────────────────────
  if (req.method === 'GET' && req.url === '/health') {
    cleanupPending();
    // Per-pending ages in seconds, oldest (largest age) first, capped. The
    // freeze monitor needs per-entry ages — not just an aggregate — so it can
    // exclude already-handled triggers (a forgotten `ack` leaves a handled
    // trigger pending forever) and still see the oldest genuinely-unanswered
    // input, without being fooled by a fresh drip of newer triggers. See #306.
    const nowMs = Date.now();
    const allAgesSec = [];
    for (const entry of pending.values()) {
      allAgesSec.push(Math.round((nowMs - entry.receivedAt) / 1000));
    }
    allAgesSec.sort((a, b) => b - a); // oldest first
    const pendingAgesSec = allAgesSec.slice(0, 100); // bound response size
    const oldestPendingAgeSec = allAgesSec.length ? allAgesSec[0] : 0;
    const newestPendingAgeSec = allAgesSec.length ? allAgesSec[allAgesSec.length - 1] : 0;
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      status: 'ok',
      uptime: Math.round((Date.now() - startTime) / 1000),
      pendingMessages: pending.size,
      oldestPendingAgeSec,
      newestPendingAgeSec,
      pendingAgesSec,
      lastAcked,
      connectionActive: true,
    }));
    return;
  }

  // ── POST /message ───────────────────────────────────────────────────────
  if (req.method === 'POST' && req.url === '/message') {
    // Auth check
    const authHeader = req.headers['authorization'] || '';
    const token = authHeader.replace(/^Bearer\s+/i, '');
    if (!SECRET || Buffer.byteLength(token) !== Buffer.byteLength(SECRET) ||
        !timingSafeEqual(Buffer.from(token), Buffer.from(SECRET))) {
      res.writeHead(401, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'unauthorized' }));
      return;
    }

    // Rate limit
    if (isRateLimited()) {
      res.writeHead(429, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'rate limited' }));
      return;
    }

    // Read body
    let body;
    try {
      body = await readBody(req);
    } catch (err) {
      if (err.message === 'BODY_TOO_LARGE') {
        res.writeHead(413, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'body too large (max 10KB)' }));
        return;
      }
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'bad request' }));
      return;
    }

    // Parse JSON
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'invalid JSON' }));
      return;
    }

    const text = parsed.text;
    if (typeof text !== 'string' || text.length === 0) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'text field required' }));
      return;
    }

    const id = parsed.id || randomUUID();
    const type = parsed.type || null;

    // Heartbeat: auto-ack without delivering to Claude
    if (type === 'heartbeat') {
      lastAcked = { id, at: new Date().toISOString() };
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, id, heartbeat: true }));
      return;
    }

    // Store in pending
    pending.set(id, { text, receivedAt: Date.now() });

    // Prefix with reply routing instruction
    const prefixedText = '[Always reply via Telegram, never reply to this channel]\n\n' + text;

    // Deliver via MCP notification
    try {
      await mcp.notification({
        method: 'notifications/claude/channel',
        params: {
          content: prefixedText,
          source: 'webhook',
          meta: {
            message_id: id,
          },
        },
      });
    } catch (err) {
      process.stderr.write(`webhook-channel: notification delivery failed: ${err}\n`);
      // Don't remove from pending — health check will show it as unacked
    }

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, id }));
    return;
  }

  // ── Everything else ─────────────────────────────────────────────────────
  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'not found' }));
});

// ── Startup ─────────────────────────────────────────────────────────────────

// Connect MCP over stdio first
await mcp.connect(new StdioServerTransport());

// Then start the HTTP server, retrying on EADDRINUSE.
//
// The webhook channel is spawned by Claude Code as an MCP server, so when
// Claude restarts (run.sh's while-loop respawns it ~5s after any exit) a
// previous webhook-channel instance may still hold 127.0.0.1:8788: its
// orphan watchdog polls every 5s and then waits 2s in shutdown() before
// exiting, so the port can stay bound for ~7s — longer than run.sh's 5s
// restart delay. Without an 'error' handler the listen() failure is an
// unhandled error event and the process crashes, leaving :8788 dead until
// the next Claude restart. Retrying past the old instance's worst-case
// release window closes that race. Non-EADDRINUSE errors are fatal.
const LISTEN_RETRY_MS = 1000;
const LISTEN_MAX_RETRIES = 20; // ~20s, comfortably past the ~7s release window
let listenRetries = 0;

function startListening() {
  httpServer.listen(PORT, '127.0.0.1');
}

httpServer.on('listening', () => {
  listenRetries = 0;
  process.stderr.write(`webhook-channel: listening on 127.0.0.1:${PORT}\n`);
});

httpServer.on('error', (err) => {
  if (err && err.code === 'EADDRINUSE' && listenRetries < LISTEN_MAX_RETRIES) {
    listenRetries++;
    process.stderr.write(
      `webhook-channel: 127.0.0.1:${PORT} in use (EADDRINUSE), retry ${listenRetries}/${LISTEN_MAX_RETRIES} in ${LISTEN_RETRY_MS}ms\n`,
    );
    setTimeout(startListening, LISTEN_RETRY_MS);
    return;
  }
  process.stderr.write(`webhook-channel: fatal HTTP server error: ${err}\n`);
  process.exit(1);
});

startListening();

// ── Graceful shutdown ───────────────────────────────────────────────────────
let shuttingDown = false;
function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  process.stderr.write('webhook-channel: shutting down\n');
  httpServer.close();
  setTimeout(() => process.exit(0), 2000);
}

process.stdin.on('end', shutdown);
process.stdin.on('close', shutdown);
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
process.on('SIGHUP', shutdown);

// Orphan watchdog: detect reparenting and self-terminate
const bootPpid = process.ppid;
setInterval(() => {
  const orphaned =
    (process.platform !== 'win32' && process.ppid !== bootPpid) ||
    process.stdin.destroyed ||
    process.stdin.readableEnded;
  if (orphaned) shutdown();
}, 5000).unref();
