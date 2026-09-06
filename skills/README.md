# Skills Registry

There are two skill locations in this repo, and they are not interchangeable:

- **`skills/`** (this folder) — reference documentation for a capability area.
  These are **not** auto-discovered by Claude Code; they are loaded because
  `CLAUDE.md` → "Tool Priority" points at them by path. Use this for guidance
  that Claude should read when it decides a task falls into that area.
- **`.agents/skills/`** — real Claude Code skills, with YAML frontmatter
  (`name`, `description`, `allowed-tools`). These are auto-discovered via
  `.claude/skills/<name>`, which `install.sh` creates as a symlink at install
  time. Use this when the model should invoke the skill on its own based on the
  description.

Each skill in either location is a self-contained folder with a `SKILL.md` and
optional scripts.

TaskRamen is focused on **small-business / SMB productivity**: producing documents,
building and shipping a web presence, marketing analytics, and lead generation — backed
by reliable APIs and libraries rather than brittle browser checkout automation.

## Reference skills (`skills/`)

| Skill | Description | Key Files |
|-------|-------------|-----------|
| `powerpoint` | Create/edit PowerPoint (.pptx) via python-pptx | `SKILL.md`, scripts |
| `excel` | Create/edit Excel (.xlsx) via openpyxl | `SKILL.md`, scripts |
| `word` | Create/edit Word (.docx) via python-docx | `SKILL.md`, scripts |
| `pdf` | Create/convert/edit PDFs (reportlab, pypdf, pdfplumber, LibreOffice) | `SKILL.md`, `example.py` |
| `libreoffice` | Headless Office ↔ PDF ↔ ODF conversion (pptx/xlsx/docx → pdf) | `SKILL.md` |
| `website-builder` | Build, deploy & manage SME websites on Cloudflare + Astro — new builds and existing-site takeovers (Git-connected Pages, Keystatic CMS, business tools: HubSpot CRM, Stripe, Shopify, scheduling; connections via `claudeconnectorskillheadless/connectorskill.md`) | `SKILL.md` |
| `google-flights` | SerpAPI flight search + browser fallback | `SKILL.md` |
| `update-location` | Update VM_COUNTRY/USER_TIMEZONE/VM_CITY in .env | `SKILL.md` |

## Auto-discovered skills (`.agents/skills/`)

| Skill | Description | Key Files |
|-------|-------------|-----------|
| `agent-browser` | Browser automation — navigation, forms, snapshots, extraction. Documents the [vercel-labs/agent-browser](https://github.com/vercel-labs/agent-browser) CLI (Apache-2.0), which is installed separately; see THIRD_PARTY_NOTICES.txt | `SKILL.md`, `references/`, `templates/` |
| `browser-intervention` | Hand control of the browser to the user (bot check, OTP, payment confirmation) via the viewer + Cloudflare tunnel | `SKILL.md` |

> **Google Workspace REST surfaces (Docs, Slides, Sheets, Gmail, Calendar, Drive)** do not live here — they are documented under `docs/` and routed from `CLAUDE.md` → "Google Workspace": `docs/google-docs-api.md`, `docs/google-slides-api.md`, `docs/google-rest-api.md` (+ the `examples/*-example.js` starters). Don't recreate them as skill folders.

## Adding a New Skill

**A reference skill** (Claude reads it when routed there from `CLAUDE.md`):

1. Create `skills/<skill-name>/SKILL.md`
2. Add any reusable scripts (example.js, etc.)
3. Add an entry to the reference-skills table above
4. Reference it from `CLAUDE.md` → "Tool Priority"

**An auto-discovered skill** (Claude invokes it on its own):

1. Create `.agents/skills/<skill-name>/SKILL.md` with YAML frontmatter —
   `name`, a `description` written so the model can tell when it applies, and
   `allowed-tools`
2. Add an entry to the auto-discovered table above
3. Re-run `install.sh` (or `install/config.sh`) so the `.claude/skills/<name>`
   symlink is created. Do not commit that symlink — it is generated, and a
   committed symlink checks out as a plain text file on Windows.
