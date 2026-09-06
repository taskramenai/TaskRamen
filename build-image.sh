#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# build-image.sh — rebuild the TaskRamen.ai container image and push it to GHCR.
#
# Usage:
#   ./build-image.sh             # pull default branch, build + push (prompts for PAT)
#   ./build-image.sh --no-push   # build only, no credentials needed
#   ./build-image.sh --no-pull   # build the checkout as-is (local/dev changes)
#   ./build-image.sh --no-scan   # skip the Trivy image scan (not recommended)
#
# The Containerfile is self-contained: app code is mounted at runtime, so the
# build needs NO secrets. Two PATs may be prompted for interactively:
#   - GitHub PAT (repo read) — only if pulling the default branch fails with the
#     credentials already stored on the machine (e.g. embedded PAT expired)
#   - GHCR PAT (write:packages) — always, before pushing the image
# Both are used ephemerally: hidden input, handed to git/podman via
# GIT_ASKPASS env / --password-stdin (never argv — argv is visible in `ps`),
# never written to disk or config, and dropped before the script exits.
#
# Run this wherever podman (or docker) is available — e.g. inside the Podman
# machine on Windows:  podman machine ssh  →  cd ~/taskramen && ./build-image.sh
#
# Rebuilding matters for the BAKED runtime — Chromium, Node, Bun, cloudflared,
# LibreOffice and the pinned Python libs all come from the image, and installs
# pull :latest, so an aging image means an aging runtime. See
# TaskRamenInstaller issue #92.
#
# It does NOT refresh Claude Code. Claude Code is deliberately not baked (it is
# not redistributable — see Containerfile step 6); entrypoint.sh installs it at
# first run into $CLAUDE_HOME/.npm-global, which lives on the persistent bind
# mount and is a no-op once bin/claude exists, and ENV DISABLE_AUTOUPDATER=1
# stops it self-updating. So a given install stays on whatever version it first
# booted with, whatever image it runs.

set -euo pipefail

IMAGE_REPO="${IMAGE_REPO:-ghcr.io/taskramenai/taskramen}"
GHCR_USER_DEFAULT="taskramenai"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -f Containerfile ]]; then
    echo "ERROR: Containerfile not found in $SCRIPT_DIR — run from the TaskRamen repo root." >&2
    exit 1
fi

NO_PUSH=false
NO_PULL=false
NO_SCAN=false
for arg in "$@"; do
    case "$arg" in
        --no-push) NO_PUSH=true ;;
        --no-pull) NO_PULL=true ;;
        --no-scan) NO_SCAN=true ;;
        *) echo "ERROR: unknown option '$arg' (valid: --no-push, --no-pull, --no-scan)" >&2; exit 1 ;;
    esac
done

# Update to the latest default branch before building, so a stale checkout can't
# silently bake an old Containerfile. Wrapped in a function and finished with
# exec: the pull can rewrite THIS script while bash is still reading it from a
# byte offset, so the only safe continuation is to re-exec the fresh copy
# (with --no-pull to not loop). ff-only + clean-tree check: never merge or
# discard local work — fail loudly and let the operator decide.
#
# Auth: the repo is private. The first fetch attempt uses whatever credential
# the remote already has (the installer embeds a read PAT in the origin URL).
# If that fails — PAT expired, missing, or revoked — prompt for a GitHub PAT
# (repo read scope) and retry. The prompted PAT is used ephemerally: passed to
# git via GIT_ASKPASS + an env var (never argv, never written to git config or
# any file) and unset immediately after the fetch.
self_update() {
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo "WARNING: not a git checkout — building as-is (cannot pull)." >&2
        return 0
    fi
    # Only the Containerfile feeds the image (no COPY of app code), so it is
    # the only file whose local modification must block a release build. A
    # live install legitimately drifts elsewhere (nightly review edits docs,
    # runtime writes state), and the Windows-backed mount can report phantom
    # mode changes — hence -c core.filemode=false and the warn-only policy
    # for everything that isn't the Containerfile. (-uno: untracked junk is
    # irrelevant too.)
    if ! git -c core.filemode=false diff --quiet HEAD -- Containerfile 2>/dev/null; then
        echo "ERROR: Containerfile has local modifications — refusing to release an" >&2
        echo "       unreviewed image. Commit the change, or build it deliberately" >&2
        echo "       with --no-pull." >&2
        exit 1
    fi
    local drift
    drift=$(git -c core.filemode=false status --porcelain -uno 2>/dev/null)
    if [[ -n "$drift" ]]; then
        echo "NOTE: working tree has local changes (normal runtime drift on a live"
        echo "      install — they don't affect the image; continuing):"
        echo "$drift" | head -10
    fi

    # Resolve the default branch by name so `main` and `master` both work.
    # origin/HEAD is recorded at clone time; fall back to the checked-out
    # branch for a tree that was git-init'ed and wired to a remote by hand.
    local branch
    branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) || branch=""
    branch="${branch#origin/}"
    [[ -n "$branch" ]] || branch=$(git rev-parse --abbrev-ref HEAD)

    echo "== Updating to latest origin/$branch"
    local merge_ref="origin/$branch"
    # GIT_TERMINAL_PROMPT=0 + askpass=true: fail fast on bad/missing stored
    # credentials instead of letting git throw its own interactive prompt —
    # the controlled PAT prompt below handles that case uniformly.
    if ! GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true git fetch origin "$branch"; then
        echo "== Stored git credentials didn't work (embedded repo PAT missing or expired)."
        if [[ ! -t 0 ]]; then
            echo "ERROR: cannot prompt for a GitHub PAT without an interactive terminal." >&2
            echo "       Re-run from a terminal, or build the checkout as-is with --no-pull." >&2
            exit 1
        fi
        read -rsp "GitHub PAT with repo read access (input hidden): " GIT_PAT
        echo
        if [[ -z "$GIT_PAT" ]]; then
            echo "ERROR: no PAT entered — aborting." >&2
            exit 1
        fi
        # Fetch the canonical https URL with any embedded (stale) credential
        # stripped, so the prompted PAT is actually the one used. Handles ssh
        # remotes too. The PAT travels via the GIT_ASKPASS env hop only.
        local clean_url askpass
        clean_url=$(git remote get-url origin \
            | sed -e 's#^git@github\.com:#https://github.com/#' \
                  -e 's#^https://[^@/]*@#https://#')
        askpass=$(mktemp)
        # Static helper — contains no secret; the PAT stays in the env var.
        printf '%s\n' '#!/bin/bash' \
            'case "$1" in Username*) echo "x-access-token" ;; *) echo "$GIT_PAT" ;; esac' \
            > "$askpass"
        chmod 700 "$askpass"
        export GIT_PAT
        GIT_ASKPASS="$askpass" git fetch "$clean_url" "$branch" || {
            rm -f "$askpass"; unset GIT_PAT
            echo "ERROR: fetch still failing with the provided PAT — check its scope (repo read) and expiry." >&2
            exit 1
        }
        rm -f "$askpass"
        unset GIT_PAT
        merge_ref="FETCH_HEAD"
    fi

    git checkout "$branch" >/dev/null 2>&1

    # Runtime-owned files that upstream may stop tracking. On a live install
    # these hold live state — install/config.sh rewrites ~/.claude/settings.json
    # with absolute hook paths (in container mode ~/.claude is a symlink into
    # this checkout), and projects/README.md is the live projects index. A merge
    # that stops tracking such a file hurts either way: if it is locally
    # modified, git refuses to fast-forward
    #
    #   error: Your local changes to the following files would be overwritten
    #          by merge: .claude/settings.json
    #
    # and if it is clean, the merge silently DELETES the working copy. The drift
    # check above is warn-only for everything but the Containerfile, so neither
    # case is caught there. Stash the live copy aside whenever it is tracked
    # (modified or not), let the merge remove the tracked one, then put it back
    # untracked (it is gitignored from that commit on). Restoring is safe in
    # every case: once untracked upstream the restored copy is invisible to git,
    # and if upstream still tracks it the restored copy is byte-identical (clean
    # case) or reinstates the same local modification that was there before.
    local preserved=()
    local runtime_owned=(".claude/settings.json" "projects/README.md")
    local f
    for f in "${runtime_owned[@]}"; do
        if git ls-files --error-unmatch "$f" >/dev/null 2>&1 && [[ -f "$f" ]]; then
            cp -p "$f" "$f.preupdate" 2>/dev/null || continue
            git checkout -- "$f" 2>/dev/null || true
            preserved+=("$f")
            echo "NOTE: set aside local $f (restored after update)"
        fi
    done

    restore_preserved() {
        local p
        for p in "${preserved[@]:-}"; do
            [[ -n "$p" && -f "$p.preupdate" ]] || continue
            mkdir -p "$(dirname "$p")" 2>/dev/null || true
            mv -f "$p.preupdate" "$p" 2>/dev/null || true
        done
    }

    git -c core.filemode=false merge --ff-only "$merge_ref" || {
        restore_preserved
        echo "ERROR: could not fast-forward to $merge_ref — either local $branch" >&2
        echo "       has diverged, or local changes above conflict with incoming" >&2
        echo "       commits. Resolve them, or build the checkout as-is with --no-pull." >&2
        exit 1
    }
    restore_preserved
    local extra=()
    $NO_PUSH && extra+=(--no-push)
    $NO_SCAN && extra+=(--no-scan)
    exec "$0" --no-pull "${extra[@]}"
}
$NO_PULL || self_update

# Prefer podman (the deployment runtime); fall back to docker for dev boxes.
if command -v podman >/dev/null 2>&1; then
    ENGINE=podman
elif command -v docker >/dev/null 2>&1; then
    ENGINE=docker
else
    echo "ERROR: neither podman nor docker found on PATH." >&2
    exit 1
fi

# Tag :latest plus an immutable date tag so installs can pin and a bad
# :latest can be rolled back by retagging a previous date tag.
DATE_TAG="$(date +%Y%m%d)"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

echo "== Building $IMAGE_REPO:latest (+ :$DATE_TAG) with $ENGINE  [repo @ $GIT_SHA]"
"$ENGINE" build -t "$IMAGE_REPO:latest" -t "$IMAGE_REPO:$DATE_TAG" .

# Claude Code is deliberately NOT baked into the image — it is proprietary and
# not redistributable, so each install pulls the current version at first run
# (see deps_ensure_claude_code / entrypoint.sh). Hard-fail if a stray bake slips
# back in: this script also pushes to GHCR, so a mere warning could be ignored
# and ship a non-redistributable image.
if "$ENGINE" run --rm --entrypoint bash "$IMAGE_REPO:latest" \
    -c 'source $NVM_DIR/nvm.sh >/dev/null 2>&1; command -v claude' >/dev/null 2>&1; then
    echo "== ERROR: Claude Code is present in the image — it must NOT be baked (not redistributable). Check Containerfile." >&2
    exit 1
else
    echo "== Claude Code not baked (correct) — pulled at first run on the user's machine."
fi

# Scan the built image BEFORE any push. The image bakes only well-established
# third-party runtime (Ubuntu, Chromium, Node, Bun, cloudflared, ...) and no
# app code or user data, so the policy is split:
#   - secret: HARD FAIL on any finding — a leaked credential must never ship.
#   - vuln:   INFORMATIONAL only (--exit-code 0). CVEs in third-party base
#             packages are out of scope for this gate and would otherwise
#             block every release on issues we can't fix here; the table is
#             still printed for visibility but never fails the build.
# PII is covered separately (the OpenRouter PII workflows scan repo source)
# and cannot enter the image anyway — nothing is COPYed in; the app dir is
# mounted at runtime.
# Engine-agnostic: scan a saved tarball via --input, which works identically
# under podman and docker without needing a running podman API socket.
run_image_scan() {
    if $NO_SCAN; then
        echo "== --no-scan: skipping Trivy image scan (not recommended)."
        return 0
    fi
    if ! command -v trivy >/dev/null 2>&1; then
        echo "ERROR: trivy not found on PATH — it gates the image before push." >&2
        echo "       Install it (https://trivy.dev/latest/getting-started/installation/)" >&2
        echo "       or re-run with --no-scan to bypass (not recommended)." >&2
        exit 1
    fi
    local tar
    tar=$(mktemp --suffix=.tar)
    # RETURN trap is function-scoped: removes the (large) tarball whether the
    # scan passes, fails, or the script exits via set -e inside trivy.
    trap 'rm -f "$tar"' RETURN
    echo "== Exporting image for scan"
    "$ENGINE" save "$IMAGE_REPO:latest" -o "$tar"

    echo "== Trivy: secret scan (hard fail on any finding)"
    trivy image --quiet --scanners secret --exit-code 1 --input "$tar"

    echo "== Trivy: vulnerability scan (informational only — does not block)"
    trivy image --quiet --scanners vuln --ignore-unfixed \
        --severity HIGH,CRITICAL --exit-code 0 --input "$tar"

    echo "== Trivy: secret scan passed (vuln findings above are informational)."
}
run_image_scan

if $NO_PUSH; then
    echo "== --no-push: done. Built $IMAGE_REPO:latest and :$DATE_TAG locally."
    exit 0
fi

if [[ ! -t 0 ]]; then
    echo "ERROR: push requires an interactive terminal to prompt for the PAT." >&2
    echo "       Re-run from a terminal, or use --no-push and push manually." >&2
    exit 1
fi

read -rp "GitHub username [$GHCR_USER_DEFAULT]: " GHCR_USER
GHCR_USER="${GHCR_USER:-$GHCR_USER_DEFAULT}"
read -rsp "GitHub PAT with write:packages scope (input hidden): " GHCR_PAT
echo
if [[ -z "$GHCR_PAT" ]]; then
    echo "ERROR: no PAT entered — aborting before push." >&2
    exit 1
fi

# Always drop the GHCR credential when we leave, even on a failed push:
# login writes it to the engine's auth.json, which must not outlive this run.
cleanup() { "$ENGINE" logout ghcr.io >/dev/null 2>&1 || true; }
trap cleanup EXIT

printf '%s' "$GHCR_PAT" | "$ENGINE" login ghcr.io -u "$GHCR_USER" --password-stdin
unset GHCR_PAT

echo "== Pushing $IMAGE_REPO:latest"
"$ENGINE" push "$IMAGE_REPO:latest"
echo "== Pushing $IMAGE_REPO:$DATE_TAG"
"$ENGINE" push "$IMAGE_REPO:$DATE_TAG"

echo "== Done. Pushed :latest and :$DATE_TAG."
echo "   Existing installs pick this up on their next reinstall / 'podman pull'."
