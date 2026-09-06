# Project Structure

## System Folders (do NOT put task/project files here)

These folders are part of the assistant infrastructure and are tracked in git:

- **`core/`** — Runtime shell scripts and Python daemons that keep the assistant running: process monitor (`monitor.sh`), browser launcher (`start-browser.sh`), OpenRouter bridge (`openrouter-bridge.py`), nightly review (`nightly-review.sh`), on-demand safe restart (`restart.sh`) and its shared restart helpers (`restart-lib.sh`), proxy toggle (`toggle-proxy.sh`). Add here only if it is a persistent system-level script.
- **`browser-viewer/`** — Browser intervention system: tunnel scripts, viewer UI (`index.html`), WebSocket server (`server.js`). The agent-facing runbook is the `browser-intervention` skill under `.agents/skills/`. Add here only for intervention infrastructure changes.
- **`docs/`** — Reference documentation: Puppeteer patterns, API guides, form-filling guides, web-access guidance. Add here if it is a reusable how-to (not tied to a specific task).
- **`examples/`** — Runnable starter scripts to copy from (Google Docs/Slides). Add here if it is a generic, self-contained script meant to be adapted, not imported.
- **`skills/`** — Reference skills: `SKILL.md` docs for a capability area, routed from `CLAUDE.md` → "Tool Priority". Not auto-discovered.
- **`.agents/skills/`** — Auto-discovered Claude Code skills, with YAML frontmatter. Published into `.claude/skills/` by `core/link-skills.sh` at install/boot; never commit anything under `.claude/skills/`. See `skills/README.md` for which of the two a new skill belongs in.
- **`config/`** — Configuration templates and systemd service definitions. Add here only for infrastructure config changes.
- **`install/`** — Installer stages invoked by `install.sh`. `install/functionalitycheck.md` is the manual post-install smoke test, run by hand.

## Projects Folder (all task/project-specific work goes here)

`projects/<project-name>/` — one subfolder per task or project. Examples: `projects/quarterly-review-deck/`, `projects/market-research/`, `projects/invoice-cleanup/`.

`projects/README.md` is the **index** of all projects (one line per project: name, goal, status). It is read on demand, not auto-loaded, so it costs no standing context. Keep it current.

## Keeping project data out of git

**Nothing under `projects/` is tracked — including the index.** Write whatever
detail is actually useful in there: real client names, deal values, contacts,
personal notes. None of it is in git, and none of it can reach GitHub without
deliberately defeating three independent guards.

The index used to be the one tracked exception, on the theory that it held only
short neutral descriptions. It did not stay neutral — it accumulated client
names, a co-owned business and an unfiled product concept, because the whole
point of an index is to be useful at a glance. The exception was the leak, so
the exception is gone. No template is shipped either: the index is derived data
(every project folder carries its own `CLAUDE.md`), so Claude creates
`projects/README.md` the first time a project is registered and rebuilds it
from `projects/*/CLAUDE.md` whenever it is missing — see CLAUDE.md → "Project
Structure". A lost index is therefore an inconvenience, not data loss.

| Layer | Mechanism | Defeated by |
|---|---|---|
| 1 | `.gitignore` — `projects/*`, allowing only `.gitkeep` | `git add -f` |
| 2 | `core/git-hooks/pre-commit` — refuses to commit user-data paths even when force-staged | `git commit --no-verify`, or a clone that never ran `install.sh` |
| 3 | `.github/workflows/guard-tracked-paths.yml` — fails the build if any such path is tracked | nothing client-side |

Layers 1 and 2 are conveniences that catch honest mistakes. **Layer 3 is the
actual guarantee**, because it runs on GitHub rather than on the machine making
the commit. For it to be a guarantee rather than a warning it must be a
**required status check** on the default branch —
Settings → Branches → branch protection → Require status checks → `guard`.
That is a one-time repository setting and is not something a commit can
configure.

The hook is installed by `install.sh` via `git config core.hooksPath
core/git-hooks`, which lives in the repo rather than `.git/hooks`, so it
survives re-clones and updates. To install it by hand:

```bash
git config core.hooksPath core/git-hooks
```

The same rule set covers `personalinfo.md`, `.env`, `claudebot.env`,
`.crontab`, `.claude/settings.json`, `.claude/skills/` and any
`*.credentials.json`. The hook and the workflow duplicate the list by necessity
(each has to run without the other present), and the workflow's second step
fails if the two ever drift apart.

**None of this helps retroactively.** Removing a file at HEAD leaves it in
history and, if it was pushed, in every clone and in GitHub's API. If something
sensitive lands, treat it as disclosed: rotate any secret, and rewrite history
only as a secondary cleanup.

### When to create a project
Create one for any of:
- File creation/manipulation (outputs, data, notes)
- Coding (scripts or files written for the task)
- Multi-step tasks or anything spanning multiple sessions
- Deliverables (docs, reports)

Skip it only for quick one-off answers with no files.

### Naming
- kebab-case, descriptive: `<topic>-<type>` — e.g. `flights-tokyo`, `invoice-cleanup`, `market-research`.

### On create — do both, in order
1. Create the subfolder and its `CLAUDE.md` **before any other file**. The `CLAUDE.md` records:
   - **Goal** — what the project is and what done looks like
   - **Files** — each file/subfolder and its purpose
   - **Linkages** — external references: Google Doc URLs, spreadsheet IDs, calendar event IDs, booking refs
2. Add a one-line entry to the index `projects/README.md`.

Then tell the user the project name and how to refer to it. Always establish which project is in scope before making changes.

### Rules
- Any file created for a specific task goes in its project subfolder — never in system folders or the root.
- Projects are fully independent — no shared context, dependencies, or conventions between them.
- Why `CLAUDE.md` (not `PROJECT.md`/`README.md`) per project: Claude Code auto-loads `CLAUDE.md` as context when working inside that folder, so the project's goal and state are always in view without an explicit read.

### Deliverables
For long research or reports (3+ parts or significant length), compile into a **Google Doc** rather than only sending Telegram messages, and save the Doc URL in the project `CLAUDE.md`. If Google Workspace isn't connected, produce a **Word** document instead, save it in the project subfolder, record its path in the project `CLAUDE.md`, and send it to the user.
