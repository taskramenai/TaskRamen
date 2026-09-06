# Post-Install Functionality Tests

Run the main set of instructions in the foreground, not as background agent (but where background agent is specified here, run as background)

Run these tests after installation to verify all services are working correctly.
Each test group should be run as a background agent. Report results via Telegram.

---

## Test 1: Scheduling (one-time, recurring, deletion)

Start a background agent and do the following:
1. Set a reminder 5 minutes from now to take a walk
2. Set a reminder 5 minutes from now to fly a kite
3. Set a recurring reminder every 10 minutes to do squats
4. 30 minutes from now, remove the squats recurring task using delete-task.sh

After you have scheduled the tasks above, send a Telegram to user to inform user what tasks you have setup

**Expected:** All reminders arrive via Telegram at the correct times. The squats task fires a few times then stops after deletion. Verify the crontab shows #JOB_ tags for one-time tasks and #RECUR_ tag for the recurring task.

---

## Test 2: Webhook channel

Start a background agent and test the webhook channel by sending a test message through the webhook (port 8788). Verify the message is received and processed.

**Expected:** Webhook message is received and forwarded via Telegram.

---

## Test 3: Browser + Cloudflare tunnel


Start a background agent and:
1. Use the browser (agent-browser --cdp 9222) to navigate to the Wikipedia page on apples
2. Start a Cloudflare tunnel to the browser viewer
3. Send the tunnel URL via Telegram so the user can view the page. Be sure to include required token
After this background agent is started, send user a telegram informing that you are testing the browser and tunnel by navigating to Wikipedia

**Expected:** Browser loads the page, tunnel URL is accessible, and the user can see the Wikipedia page through the browser viewer.

---

## Test 4: SerpAPI (skip if not connected)

If SerpAPI is connected (`SERPAPI_KEY` in `.env`), start a background agent to:
1. Use SerpAPI to search Google Flights for flights from the user's nearest major airport (infer from `VM_CITY`/`VM_COUNTRY` in `.env`) to a major city a few hours' flight away, departing 3 days from now

**Expected:** Flight results are returned and summarised via Telegram.

---

## Test 5: Google Workspace (skip if not connected)

If Google Workspace MCP is connected, start a background agent to:
1. Send a test email to the service account email
2. Create a test Google Doc
3. Create a test Google Sheet
4. Create a test Google Slides presentation
5. Create a test calendar event at the current time
6. Verify the email is received and all documents are accessible (try reading/opening each one)

**Expected:** All 5 Google services respond successfully. Documents are created and accessible. Email is received.

---

## Test 6: Agent watcher

For each of the background agents above, verify that the agent status watcher is working:
- Status webhooks should arrive every 2 minutes while agents are running
- Check that Telegram receives status update messages for each active agent

**Expected:** Periodic "Status of [agent]: ..." messages appear in Telegram while agents are active.

---

## Test 7: Reply-gate hooks

**MUST run in the foreground main session — this overrides the "Background Agents — MANDATORY" rule for this test only.** The gate under test is the main session's own Stop hook: a background agent ends with SubagentStop (no nudge ever fires there), so steps 1–3 run inside an agent report a false failure, step 4's flag-touching would pollute the live main-session gate, and step 5 would need an agent to spawn an agent (forbidden).

First verify registration: `~/.claude/settings.json` must contain reply-gate.sh entries under `UserPromptSubmit`, `MessageDisplay`, `PostToolUse`, and `Stop`. Then:

1. **Nudge fires:** in a fresh turn, deliberately end the turn with terminal text only — do NOT call the Telegram reply tool. The turn should not end silently: a `REPLY GATE:` nudge must come back telling you to resend via `mcp__plugin_telegram_telegram__reply`. Comply, then confirm the message arrived in Telegram.
2. **One-shot (no loop):** in the nudged continuation, if you deliberately end again WITHOUT replying, the turn must end normally — no second nudge (stop_hook_active honored).
3. **No false nudge (MCP path):** answer a turn normally, ending with a `reply` tool call. The turn must end with no nudge.
4. **No false nudge (curl fallback):** send a message via a direct Bot API `sendMessage` curl (token/chat_id from `.env`) and end the turn with terminal text. No nudge should fire.
5. **Subagent unaffected:** spawn a trivial background agent whose final output is plain text with no Telegram call. Its result must come back clean — no `REPLY GATE:` text injected into the agent's output (Stop must not fire for subagents; if a nudge appears here, report it as a failure).

**Expected:** Nudge appears exactly once for a terminal-only turn (1), never loops (2), never fires on legitimate sends (3, 4), and never touches subagents (5). Report each sub-result via Telegram.

---

## Test 8: Agent prompt injection (guardrails reach background agents)

Proves the PreToolUse hook (`core/hooks/inject-agent-prompt.sh`) actually delivers `core/agentprompt.md` into every spawned agent — not just that the hook runs. A `hook_success` attachment in the transcript only proves the hook executed and what it printed; it does NOT prove the modification was applied (issue #484: the hook succeeded for months while every agent spawned with the raw, guardrail-free prompt).

**The spawn in step 1 MUST be made from the main session** — hooks do not fire for tool calls made inside a subagent, so a background agent spawning the probe would test nothing. The transcript greps in steps 2–3 are main-session-exempt transcript verification.

First verify registration: `~/.claude/settings.json` must contain a `PreToolUse` entry with matcher `Agent` whose command is `core/hooks/inject-agent-prompt.sh`. Then:

1. **Live injection — agent self-report:** from the main session, spawn a background agent (`run_in_background: true`) with exactly this prompt: *"Diagnostic probe. Do NOT use any tools. Make your final output exactly two lines: line 1 = the first ten words of the instructions you received before this probe text; line 2 = YES or NO: do your instructions contain the exact phrase 'NO SUBAGENTS'?"* — line 1 must begin "**You ARE the background agent" and line 2 must be YES. If line 1 is the probe text itself or line 2 is NO, injection is broken.
2. **Transcript proof:** after the probe completes, locate its subagent transcript (newest `agent-*.jsonl` under `~/.claude/projects/*/`) and run `grep -c "NO SUBAGENTS" <file>` — must be ≥ 1 (`NO SUBAGENTS` appears only in `agentprompt.md`, so the auto-loaded CLAUDE.md cannot false-positive this). The transcript's first user message must be the agentprompt.md rules, then a `---` separator, then the probe prompt.
3. **No spawn-loop regression:** in the same transcript, confirm the probe agent made zero `Agent` tool_use calls and zero Telegram sends of its own — the original #484 failure mode was agents re-obeying CLAUDE.md §1 (own "⚙️ Starting…" message + nested agent) because the "You ARE the background agent" identity line never reached them.

**Expected:** Registration present, probe self-reports the injected guardrails (1), transcript physically contains them (2), and the probe neither nested a spawn nor messaged Telegram (3). Report each sub-result via Telegram.
