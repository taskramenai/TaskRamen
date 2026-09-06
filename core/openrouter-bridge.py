# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

import os, time, subprocess, requests

CLAUDE_HOME = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
dotenv_path = os.path.join(CLAUDE_HOME, '.env')

with open(dotenv_path) as f:
    for line in f:
        line = line.strip()
        # Tolerate malformed lines (no '='): a stray word in .env must not
        # crash-loop the whole Telegram bridge at startup.
        if line and not line.startswith('#') and '=' in line:
            key, val = line.split('=', 1)
            os.environ[key] = val

TOKEN = os.environ.get('TELEGRAM_BOT_TOKEN')
CHAT_ID = os.environ.get('TELEGRAM_CHAT_ID')
os.environ['TMUX_TMPDIR'] = '/tmp'

print("🚀 Tmux Telegram Injector (OpenRouter bridge) started...")
offset = 0

while True:
    try:
        # timeout= (client-side) on top of the long-poll timeout=10 query param:
        # without it a stalled connection hangs the poller forever.
        res = requests.get(f"https://api.telegram.org/bot{TOKEN}/getUpdates?offset={offset}&timeout=10", timeout=30).json()

        for update in res.get('result', []):
            if 'message' in update and 'text' in update['message']:
                text = update['message']['text']
                if str(update['message']['chat']['id']) != CHAT_ID:
                    offset = update['update_id'] + 1
                    continue

                # Format the injection prompt
                prompt = f"[You must reply to this message using telegram MCP not just in chat] [Telegram]: {text}"

                # Try to inject up to 6 times (waiting 3 seconds between tries)
                for _ in range(6):
                    result = subprocess.run(
                        ["/usr/bin/tmux", "-L", "claudebot", "send-keys", "-t", "claudebot", prompt, "C-m"],
                        capture_output=True, text=True
                    )

                    # If tmux is running, the injection succeeds and stderr is empty
                    if "no server running" not in result.stderr:
                        print(f"✅ Successfully injected message: {text[:20]}...")
                        break

                    print("⏳ Tmux not ready yet. Waiting 3 seconds...")
                    time.sleep(3)

            # Always mark the message as read after successfully injecting (or exhausting retries)
            offset = update['update_id'] + 1

    except Exception as e:
        time.sleep(5)
