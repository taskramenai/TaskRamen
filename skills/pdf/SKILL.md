# PDF Skill (.pdf)

Create, convert, and edit PDF files locally with open-source tools:
**reportlab** (BSD, generate from scratch), **pypdf** (BSD, edit/merge/split/encrypt),
**pdfplumber** (MIT, extract text/tables), and **LibreOffice** headless (convert
Word/Office/HTML → PDF). Use for "make a PDF", "convert this doc to PDF",
"merge/split these PDFs", "fill this form", "extract text from a PDF", etc.

## Setup
`reportlab`, `pypdf`, `pdfplumber` and `weasyprint` are pre-installed in the
container image — no install step needed.
```bash
# Only if running outside the container (e.g. a bare host):
#   pip install --quiet reportlab pypdf pdfplumber weasyprint
# For converting Office docs / HTML to PDF:
#   sudo apt-get install -y libreoffice
```

## Where files go
Always write to the active project folder: `projects/<name>/`.

---

## 1. Convert an existing document to PDF

**From Word / Excel / PowerPoint / ODF (most reliable):** use the `libreoffice`
skill — it has the read-only-container-safe command (profile + `TMPDIR` on the
persistent volume, not RAM `/tmp`):
```bash
LO_WORK="${CLAUDE_HOME:-$HOME/taskramen}/.cache/libreoffice"; mkdir -p "$LO_WORK/profile" "$LO_WORK/tmp"
TMPDIR="$LO_WORK/tmp" soffice --headless --norestore \
    -env:UserInstallation="file://$LO_WORK/profile" \
    --convert-to pdf --outdir projects/<name>/ projects/<name>/doc.docx
```
Works for `.docx`, `.xlsx`, `.pptx`, `.odt`, etc. Pair this with the `word`/`excel`/
`powerpoint` skills: generate the Office file, then convert to PDF for a read-only copy.
→ Full conversion matrix and troubleshooting: `skills/libreoffice/SKILL.md`.

**From HTML/CSS (for designed one-pagers, invoices, reports):**
```bash
# Accurate CSS rendering (weasyprint is pre-installed):
python3 -c "from weasyprint import HTML; HTML('projects/<name>/page.html').write_pdf('projects/<name>/page.pdf')"
# or via LibreOffice (see skills/libreoffice/SKILL.md for the full command):
#   soffice --headless -env:UserInstallation=... --convert-to pdf --outdir projects/<name>/ projects/<name>/page.html
```

---

## 2. Create a PDF from scratch (reportlab)

Use `skills/pdf/example.py` as a starting template. Core pattern (flowables / Platypus):
```python
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle
from reportlab.lib import colors
from reportlab.lib.units import cm

styles = getSampleStyleSheet()
doc = SimpleDocTemplate("projects/<name>/invoice.pdf", pagesize=A4)
story = [
    Paragraph("Invoice #1042", styles["Title"]),
    Spacer(1, 0.5 * cm),
    Paragraph("Acme Pte Ltd", styles["Normal"]),
    Spacer(1, 0.5 * cm),
    Table(
        [["Item", "Qty", "Amount"], ["Consulting", "10h", "$1,200"]],
        style=TableStyle([
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#1F49E0")),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
            ("GRID", (0, 0), (-1, -1), 0.5, colors.grey),
        ]),
    ),
]
doc.build(story)
```
For pixel-perfect designed layouts, it's often easier to build an HTML/CSS page and convert
it (section 1) than to position everything by hand in reportlab.

---

## 3. Edit existing PDFs (pypdf)

**Merge:**
```python
from pypdf import PdfWriter
w = PdfWriter()
for f in ["a.pdf", "b.pdf"]:
    w.append(f)
w.write("projects/<name>/merged.pdf"); w.close()
```

**Split / extract pages, rotate:**
```python
from pypdf import PdfReader, PdfWriter
r = PdfReader("in.pdf"); w = PdfWriter()
w.add_page(r.pages[0])                 # first page only
w.pages[0].rotate(90)                  # rotate it
w.write("out.pdf")
```

**Watermark / stamp** (overlay a reportlab-made layer onto each page):
```python
from pypdf import PdfReader, PdfWriter
base = PdfReader("in.pdf"); stamp = PdfReader("watermark.pdf").pages[0]
w = PdfWriter()
for page in base.pages:
    page.merge_page(stamp)
    w.add_page(page)
w.write("stamped.pdf")
```

**Encrypt / password-protect:**
```python
from pypdf import PdfReader, PdfWriter
r = PdfReader("in.pdf"); w = PdfWriter(); w.append_pages_from_reader(r)
w.encrypt(user_password="secret")
w.write("locked.pdf")
```

**Fill AcroForm fields:**
```python
from pypdf import PdfReader, PdfWriter
r = PdfReader("form.pdf"); w = PdfWriter(); w.append(r)
w.update_page_form_field_values(w.pages[0], {"full_name": "Jane Doe", "email": "jane@example.com"})
w.write("filled.pdf")
```

---

## 4. Extract text / tables (pdfplumber)

```bash
python3 - <<'PY'
import pdfplumber
with pdfplumber.open("projects/<name>/report.pdf") as pdf:
    for i, page in enumerate(pdf.pages, 1):
        print(f"--- page {i} ---")
        print(page.extract_text() or "")
        for table in page.extract_tables():
            for row in table:
                print(row)
PY
```
For scanned/image-only PDFs there's no text layer — OCR with `ocrmypdf` (`sudo apt-get
install ocrmypdf`) first, then extract.

---

## QA before delivering
1. Reopen the output and extract text (section 4) to confirm content/quote integrity.
2. Check page count and that no pages are blank/rotated wrong.
3. Send the `.pdf` via the file-send tool.
