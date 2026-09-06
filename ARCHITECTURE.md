# Architecture

How TaskRamen is put together, how to deploy it, and what its security model is. For what it
does and why you'd want it, see [`README.md`](README.md).

## Overview

```
                    Telegram
                       |
            +----------+----------+
            |                     |
     [claudebot.service]   [openrouter-bridge.service]
     tmux -> run.sh ->     (fallback when Claude
     Claude Code CLI       rate-limited: polls
            |              Telegram, injects to tmux)
            |
     [claudemonitor.service]
     Watches tmux pane for
     rate limits & freezes
            |
     [stealth-chrome.service]
     Xvfb + Chrome CDP:9222
     (agent-browser, Puppeteer)
            |
     [claude-router.service]
     OpenRouter proxy (on-demand)
```

You bring your own Anthropic account; this repository is the orchestration layer around Claude
Code, not an AI model.

## Two ways to run it

TaskRamen supports two deployment modes. Both run the same code and the same `install.sh`
wizard; they differ only in what hosts the process.

### A. Container (Podman/Docker)

The container image provides Node, Chromium, Bun and cloudflared. Application code is
bind-mounted from the host, so all state persists across image updates. `entrypoint.sh` is
PID 1: it validates install state, runs the wizard if needed, then supervises the services.

```bash
git clone https://github.com/taskramenai/TaskRamen.git ~/taskramen
cd ~/taskramen
podman build -t taskramen .

# First run — interactive, runs the install wizard
podman run -it --sig-proxy=false --restart=unless-stopped --name taskramen \
  --userns=keep-id --memory=3g --cpus=2 --shm-size=2g \
  --cap-drop=ALL --security-opt=no-new-privileges \
  --security-opt=seccomp=unconfined --read-only \
  --tmpfs /tmp:rw,nosuid,size=512m \
  --tmpfs /var/log:rw,nosuid,size=64m \
  --tmpfs /var/run:rw,nosuid,size=16m \
  --tmpfs /home/ccuser/.cache:rw,nosuid,size=256m \
  -v ~/taskramen:/home/ccuser/taskramen:Z \
  taskramen

# Subsequent runs
podman start taskramen
```

See the header of [`Containerfile`](Containerfile) for the authoritative flags.
[`build-image.sh`](build-image.sh) rebuilds and (optionally) pushes the image. It refreshes the
baked runtime (Chromium, Node, Bun, cloudflared, LibreOffice, the Python office libraries), so an
aging image means an aging runtime. It does **not** update Claude Code: that is never baked into
the image, is installed at first run onto the persistent volume, and is pinned there by
`DISABLE_AUTOUPDATER=1`.

### B. Directly on a Linux host (systemd)

```bash
git clone https://github.com/taskramenai/TaskRamen.git ~/taskramen
cd ~/taskramen
./install.sh
```

**Prerequisites:** Linux (Ubuntu 22.04+ tested), Node.js 18+, Python 3.10+, tmux, curl, Bun,
Google Chrome, Xvfb + Fluxbox, cloudflared. `install.sh` checks for these and installs what it
can.

In this mode the services in `config/systemd/` are generated, installed and enabled on the host.

## What the installer does

`install.sh` is an interactive wizard. It will:

1. Check and install required dependencies
2. Pair with your Telegram bot
3. Activate Claude Code authentication
4. Generate `.env`, `CLAUDE.md`, and systemd unit files
5. Enable and start the services
6. Optionally connect Google Workspace and SerpAPI

After installing, run `bash install/verify.sh` for an automated health check of the required
binaries, the services, Chrome/CDP, Claude authentication and Telegram; it exits non-zero if any
check fails. It does not cover scheduling, the webhook channel or the tunnel — for those,
[`install/functionalitycheck.md`](install/functionalitycheck.md) is a manual smoke-test script
that walks through them end to end.

## Directory structure

```
taskramen/
  core/               # Runtime scripts (run.sh, inject.sh, monitor.sh, etc.)
  config/             # Config templates (systemd, MCP, settings)
  install/            # Installer stages, invoked by install.sh
  skills/             # Reference docs for capability areas (office docs, website builder)
  .agents/skills/     # Claude Code skills, published into .claude/skills by core/link-skills.sh
  docs/               # API guides and reference material
  examples/           # Runnable starter scripts (Google Docs/Slides)
  browser-viewer/     # Remote browser viewer (CDP screencast + Cloudflare tunnel)
  projects/           # Task-specific subfolders (entirely gitignored)
  .env                # Secrets (gitignored)
  CLAUDE.md           # Live prompt config
  Containerfile       # Container image definition
  entrypoint.sh       # Container PID 1
  install.sh          # Interactive installer
```

## Services

| Service | Description | Script |
|---------|-------------|--------|
| `claudebot` | Main Claude Code session in tmux | `core/run.sh` |
| `claudemonitor` | Watches for rate limits and freezes | `core/monitor.sh` |
| `stealth-chrome` | Chrome on a virtual display, CDP on loopback | `core/start-browser.sh` |
| `claude-router` | OpenRouter proxy (on-demand) | system `ccr` |
| `openrouter-bridge` | Telegram bridge for fallback mode | `core/openrouter-bridge.py` |

If you exhaust your Claude usage limits, `core/toggle-proxy.sh on` switches the session to the
OpenRouter fallback (requires `OPENROUTER_API_KEY`); `core/toggle-proxy.sh off` switches back.

## Adding skills

1. Create `skills/<skill-name>/SKILL.md`
2. Add any reusable scripts
3. Update `skills/README.md` registry
4. Reference from `CLAUDE.md` as needed

See [`skills/README.md`](skills/README.md) for the full registry and for the difference between
`skills/` and `.agents/skills/`.

## Security notes

**Secrets and personal data**

- `.env` contains secrets and is gitignored
- `personalinfo.md` is gitignored (see `personalinfo.md.example` for the schema)
- `.claude/.credentials.json` and `.claude/settings.json` are gitignored
- `claudebot.env` (proxy toggle state) is gitignored
- Never commit OAuth tokens, API keys, or personal data
- The `config/*.example` files use placeholder values

**What the assistant stores locally**

- `.crontab` holds your scheduled tasks *including their verbatim prompts*
- `projects/` holds all task working files **and** the project index — none of it is tracked in
  git
- Claude Code session transcripts under `~/.claude/projects/` are read by the nightly review
  (`core/nightly-review.sh`) and the agent status watcher

All of these live on your machine. Treat the whole install directory as sensitive, and note that
anyone with shell access to the host can read it.

**Keeping local data out of git**

Because the assistant writes real client and personal detail into `projects/`, three independent
guards stop it reaching a remote: `.gitignore`, a pre-commit hook (`core/git-hooks/pre-commit`,
installed by `install.sh`), and a CI check (`.github/workflows/guard-tracked-paths.yml`) that
fails if any such path is tracked. Only the CI check is enforceable — **make `guard` a required
status check on your default branch**. Full detail, and the list of guarded paths, in
[`docs/project-structure.md`](docs/project-structure.md).

**Browser automation and stealth Chrome**

`core/start-browser.sh` runs Chrome behind `puppeteer-extra-plugin-stealth` with a persistent
profile. The purpose is to let the assistant keep using sessions *you* are already logged into,
on your own machine, without being tripped up by automation fingerprinting on sites you
legitimately use. It is not intended for evading access controls, defeating CAPTCHAs, or scraping
sites that have told you not to — and the assistant is instructed to hand control back to you
rather than work around a CAPTCHA. Whatever you automate remains your responsibility under the
terms of the sites involved.

**Remote browser viewer**

`browser-viewer/` can expose a live view of the browser through a Cloudflare quick tunnel so you
can take over on your phone. That link carries full mouse/keyboard control of a browser holding
your logged-in sessions, so:

- every request is gated on a single-use token, which expires after 10 minutes of inactivity
  (`VIEWER_SESSION_IDLE_MS`); an open viewer page keeps its own session alive, so a long hand-off
  is not cut off mid-form
- the tunnel is torn down when the session ends, goes idle, or the viewer disconnects — and the
  waiting agent is notified in every one of those cases
- minting a token requires the shared secret from `.env`
- `VIEWER_ALLOW_NO_TOKEN=1` disables the token gate. Only set it if the viewer is reachable
  solely over an SSH tunnel you control

**CDP**

Chrome's DevTools protocol on port 9222 is unauthenticated and grants full browser control. It is
bound to loopback; never expose it beyond the host.
