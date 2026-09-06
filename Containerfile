# Containerfile — TaskRamen.ai (Podman/Docker)
# Runtime-only container: provides Node, Chromium, Bun, cloudflared.
# The app directory is mounted from the host for full persistence.
# Runs as ccuser with --userns=keep-id for correct file ownership.
#
# Build:
#   podman build -t taskramen .
# Build + push to GHCR (prompts for a write:packages PAT):
#   ./build-image.sh
#
# First run (interactive — runs install wizard):
#   podman run -it --sig-proxy=false --restart=unless-stopped --name taskramen \
#     --userns=keep-id --memory=3g --cpus=2 --shm-size=2g \
#     --cap-drop=ALL \
#     --security-opt=no-new-privileges \
#     --security-opt=seccomp=unconfined \
#     --read-only \
#     --tmpfs /tmp:rw,nosuid,size=512m \
#     --tmpfs /var/log:rw,nosuid,size=64m \
#     --tmpfs /var/run:rw,nosuid,size=16m \
#     --tmpfs /home/ccuser/.cache:rw,nosuid,size=256m \
#     -v ~/taskramen:/home/ccuser/taskramen:Z \
#     taskramen
#
# Subsequent runs:
#   podman start taskramen

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# ── 1. System packages ─────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    tmux curl unzip python3 python3-pip ca-certificates gnupg git jq qrencode \
    # keyutils provides `keyctl`, the kernel-keyring sink the connector DCR daemon
    # (claudeconnectorskillheadless connectdcr.mjs --keyring) writes credentials to
    # instead of stdout/disk. Without it the daemon fails fast with NO_KEYRING and
    # the headless OAuth flow can't run. The container already runs
    # --security-opt=seccomp=unconfined (for Chromium), so add_key/keyctl are not
    # seccomp-blocked, and adding a key to the per-uid @u keyring needs no
    # capability (works under --cap-drop=ALL). License: GPL-2.0+ (the keyctl
    # programs) and LGPL-2.1+ (libkeyutils) — same redistribution terms as git
    # (GPL-2.0+) and gnupg (GPL-3.0+) already shipped here; binary redistribution
    # inside the image is permitted, with corresponding source available from
    # Debian and the package's /usr/share/doc/*/copyright notices retained.
    keyutils \
    # tzdata is load-bearing: without /usr/share/zoneinfo, GNU date silently
    # parses every TZ=<zone> as UTC, so all USER_TIMEZONE->UTC cron conversions
    # (nightly review, scheduled tasks) land at the wrong absolute time.
    tzdata \
    xvfb matchbox-window-manager \
    libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
    libxkbcommon0 libgbm1 libasound2 libxcomposite1 libxdamage1 \
    libxfixes3 libxrandr2 libpango-1.0-0 libcairo2 fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

# ── 1b. Install Chromium (real .deb, not snap) ────────────────────
RUN echo "deb [trusted=yes] http://deb.debian.org/debian bookworm main" > /etc/apt/sources.list.d/debian-bookworm.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends -t bookworm chromium && \
    rm -f /etc/apt/sources.list.d/debian-bookworm.list && \
    apt-get update && \
    rm -rf /var/lib/apt/lists/* && \
    ln -sf /usr/bin/chromium /usr/bin/chromium-browser

# ── 1c. Python libs for the office/PDF skills ──────────────────────
# Baked in (rather than pip-installed at task time) so the powerpoint,
# excel, word and pdf skills work offline / under a locked-down network
# policy, and under the --read-only runtime (a runtime `pip install`
# would fail with no writable site-packages). Installed system-wide as
# root so the system python3 imports them with no PATH/venv setup.
# All permissive licenses (MIT / BSD-3-Clause), safe to redistribute:
#   python-pptx MIT · openpyxl MIT · pandas BSD-3 · python-docx MIT
#   reportlab BSD-3 · pypdf BSD-3 · pdfplumber MIT · weasyprint BSD-3
# Versions are pinned for reproducible builds (the image is the
# distribution unit); bump deliberately when upgrading.
RUN pip3 install --no-cache-dir \
    python-pptx==1.0.2 \
    openpyxl==3.1.2 \
    pandas==2.2.1 \
    python-docx==1.1.0 \
    reportlab==4.1.0 \
    pypdf==4.1.0 \
    pdfplumber==0.11.0 \
    weasyprint==61.2

# ── 1d. LibreOffice (headless) for Office <-> PDF conversion ────────
# Powers the high-fidelity pptx/xlsx/docx -> pdf conversions used by the
# office skills (no good pure-Python path exists for pptx -> pdf).
# --no-install-recommends and NO Java keeps it to the core engine plus
# the three document filters (~400 MB) rather than the ~1 GB full suite;
# headless PDF export does not need the JRE. Licensed MPL-2.0 / LGPL-3.0
# (weak copyleft): redistributable inside the image — the obligation is
# only to keep the /usr/share/doc/*/copyright notices intact (so do NOT
# strip /usr/share/doc when slimming). At runtime the conversion skill
# redirects LibreOffice's profile + TMPDIR to a disk-backed scratch dir
# on the mounted volume, since the root FS is --read-only and /tmp is a
# small RAM tmpfs.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libreoffice-core libreoffice-writer libreoffice-calc libreoffice-impress \
    && rm -rf /var/lib/apt/lists/*

# ── 2. Create ccuser ────────────────────────────────────────────────
RUN useradd -m -s /bin/bash ccuser && \
    touch /var/log/claudebot.log && chown ccuser:ccuser /var/log/claudebot.log && \
    touch /.dockerenv

# ── 2b. Install supercronic (cron replacement, no root needed) ──────
RUN ARCH=$(uname -m) && \
    case "$ARCH" in \
        x86_64)  SC_ARCH="amd64" ;; \
        aarch64) SC_ARCH="arm64" ;; \
        *)       SC_ARCH="amd64" ;; \
    esac && \
    curl -fsSL "https://github.com/aptible/supercronic/releases/download/v0.2.33/supercronic-linux-${SC_ARCH}" \
         -o /usr/local/bin/supercronic && \
    chmod +x /usr/local/bin/supercronic

# ── 2c. Chromium expects /etc/machine-id (missing on minimal images) ─
RUN echo "taskramen" > /etc/machine-id

# ── Switch to ccuser ────────────────────────────────────────────────
USER ccuser
WORKDIR /home/ccuser
ENV HOME=/home/ccuser

# ── 3. Node.js via nvm ──────────────────────────────────────────────
ENV NVM_DIR=/home/ccuser/.nvm
RUN curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash && \
    bash -c "source $NVM_DIR/nvm.sh && nvm install --lts && \
             NODE_DIR=\$(dirname \$(which node)) && \
             mkdir -p $NVM_DIR/bin && \
             ln -sf \$NODE_DIR/node $NVM_DIR/bin/node && \
             ln -sf \$NODE_DIR/npm  $NVM_DIR/bin/npm && \
             ln -sf \$NODE_DIR/npx  $NVM_DIR/bin/npx"
ENV PATH="$NVM_DIR/bin:$PATH"

# ── 4. Bun ───────────────────────────────────────────────────────────
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/home/ccuser/.bun/bin:$PATH"

# ── 5. cloudflared ───────────────────────────────────────────────────
RUN mkdir -p ~/bin && \
    ARCH=$(uname -m) && \
    case "$ARCH" in \
        x86_64)  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;; \
        aarch64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;; \
        *)       CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;; \
    esac && \
    curl -fsSL "$CF_URL" -o ~/bin/cloudflared && chmod +x ~/bin/cloudflared
ENV PATH="/home/ccuser/bin:$PATH"

# ── 6. Install global npm packages ─────────────────────────────────
# Claude Code (@anthropic-ai/claude-code) is deliberately NOT baked into the
# image. It is proprietary (Anthropic Commercial Terms) and carries no
# redistribution right, so shipping it inside a distributed image would be
# improper. Instead it is pulled at first run, on the user's own machine,
# authenticated with the user's own Claude subscription — see
# deps_ensure_claude_code() in install/deps.sh and _ensure_claude_code() in
# entrypoint.sh. agent-browser is Apache-2.0, so it stays baked.
RUN bash -c "source $NVM_DIR/nvm.sh && npm install -g agent-browser"

# ── 7. Create symlinks for persistent dirs ──────────────────────────
ENV CLAUDE_HOME=/home/ccuser/taskramen
RUN mkdir -p /home/ccuser/taskramen && \
    ln -sf /home/ccuser/taskramen/.claude /home/ccuser/.claude && \
    ln -sf /home/ccuser/taskramen/.chrome-profile /home/ccuser/chrome-profile && \
    ln -sf /home/ccuser/taskramen/.claude/.claude.json /home/ccuser/.claude.json

# ── 8. Container environment ────────────────────────────────────────
ENV CONTAINER=true
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
# Canonical pane-log path, baked into the image env so EVERY process — the
# entrypoint tree (monitor.sh inherits it there) AND `podman exec`'d flows
# (installer, reauth, toggle-proxy, services_restart_claudebot) — resolves the
# same file. Those exec'd flows re-create the tmux pipe-pane with
# ${CLAUDEBOT_LOG:-/tmp/claudebot.log}; without this ENV they'd silently move
# the pane log to /tmp while monitor.sh TASK 1 keeps reading /var/log, going
# blind on real usage-limit banners (the /tmp-vs-/var/log split behind the
# missed session-limit alert). claudebot.env can still override — entrypoint
# loads it after this and load_env_file overwrites inherited values.
ENV CLAUDEBOT_LOG=/var/log/claudebot.log
# The image is the distribution unit — Claude Code must never self-update
# inside the container. Its in-place binary rewrite, if interrupted, leaves a
# truncated ELF that SIGBUSes on every launch (see run.sh). Covers ALL claude
# invocations (run.sh, monitor.sh's `claude auth status`), not just the
# claudebot session.
ENV DISABLE_AUTOUPDATER=1

WORKDIR /home/ccuser/taskramen

# No EXPOSE: every service (Chrome CDP :9222, browser viewer :3000, webhook
# channel :8788) binds 127.0.0.1 inside the container and must never be
# published to the network. External access to the viewer goes through the
# cloudflared tunnel started from inside the container.

ENTRYPOINT ["/bin/bash", "./entrypoint.sh"]
