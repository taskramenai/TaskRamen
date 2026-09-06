# Word Skill (.docx)

Create, read, and edit Microsoft Word documents locally with **python-docx**
(MIT-licensed). Use for any request mentioning a "Word doc", "letter", "report",
"contract", or a `.docx` file.

## Setup
`python-docx` is pre-installed in the container image — no install step needed.
```bash
# Only if running outside the container (e.g. a bare host):
#   pip install --quiet python-docx
```
To convert a document to PDF, LibreOffice is pre-installed → see `skills/libreoffice/SKILL.md`.

## Where files go
Always write to the active project folder: `projects/<name>/`.

## Reading / extracting text
```bash
python3 - <<'PY'
import docx
d = docx.Document("projects/<name>/doc.docx")
for p in d.paragraphs:
    if p.text.strip():
        print(p.style.name, "|", p.text)
for t, table in enumerate(d.tables, 1):
    print(f"-- table {t} --")
    for row in table.rows:
        print([c.text for c in row.cells])
PY
```

## Creating a document
Use `skills/word/example.py` as a starting template. Core pattern:
```python
from docx import Document
from docx.shared import Pt, Inches
from docx.enum.text import WD_ALIGN_PARAGRAPH

doc = Document()                                  # or Document("template.docx") to inherit styles
doc.styles["Normal"].font.name = "Arial"
doc.styles["Normal"].font.size = Pt(11)

doc.add_heading("Service Proposal", level=0)      # level 0 = title; 1..9 = headings (build a TOC)
doc.add_heading("Overview", level=1)
doc.add_paragraph("Acme will deliver a marketing analytics package...")

doc.add_heading("Pricing", level=1)
table = doc.add_table(rows=1, cols=2)
table.style = "Light Grid Accent 1"
hdr = table.rows[0].cells
hdr[0].text, hdr[1].text = "Item", "Monthly (USD)"
for item, price in [("Ads management", "1,200"), ("Reporting", "400")]:
    cells = table.add_row().cells
    cells[0].text, cells[1].text = item, price

doc.save("projects/<name>/doc.docx")
```

## Editing an existing document
`Document(path)`, mutate paragraphs/runs/tables in place, save (to a new filename to keep
the original). To change wording while preserving formatting, edit `run.text` on the existing
run instead of deleting and re-adding the paragraph.

## Conventions that keep docs portable
- Use real heading styles (`add_heading(..., level=N)`) so Word can auto-build a table of contents.
- Use Word's list styles (`style="List Bullet"` / `"List Number"`), not literal "-" or "1." text.
- One idea per paragraph; create separate `add_paragraph()` calls rather than embedding newlines.
- For branded output, start from the user's `template.docx` so fonts/headers/footers carry over.

## Convert to PDF (for sending a read-only copy)
```bash
libreoffice --headless --convert-to pdf --outdir projects/<name>/ projects/<name>/doc.docx
```

## QA before delivering
1. Re-extract text (reader snippet) and check for typos / leftover placeholders.
2. Confirm headings, lists, and tables render as intended (PDF preview helps).
3. Send the `.docx` (and PDF if generated) via the file-send tool.
