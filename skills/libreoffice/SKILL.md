# LibreOffice Conversion Skill (Office ↔ PDF ↔ ODF)

Headless **LibreOffice** is the reliable, high-fidelity converter between
Microsoft Office, OpenDocument, HTML and PDF. Use it for any "convert X to PDF",
"turn this deck into a PDF", "export the spreadsheet to PDF", or cross-format
(`.docx` → `.odt`, `.xlsx` → `.csv`, etc.) request. It is **pre-installed in the
container image** (`libreoffice-core` + writer/calc/impress, MPL-2.0 / LGPL-3.0).

There is **no good pure-Python path for `.pptx` → PDF** — LibreOffice is the tool.
For PDF *creation from scratch* / merge / split / text extraction, use the `pdf`
skill (reportlab/pypdf/pdfplumber) instead; for building a `.docx`/`.xlsx`/`.pptx`,
use the `word`/`excel`/`powerpoint` skills.

## The one command to use (read-only container safe)

The container root filesystem is `--read-only` and `/tmp` is a small RAM tmpfs,
so LibreOffice cannot create its default profile under `$HOME` and must not spool
large jobs into RAM. Always redirect both the **profile** and **`TMPDIR`** to a
disk-backed scratch dir on the mounted (persistent) volume:

```bash
# Disk-backed scratch on the persistent ~/taskramen volume — NOT RAM /tmp.
LO_WORK="${CLAUDE_HOME:-$HOME/taskramen}/.cache/libreoffice"
mkdir -p "$LO_WORK/profile" "$LO_WORK/tmp"

TMPDIR="$LO_WORK/tmp" soffice --headless --norestore \
    -env:UserInstallation="file://$LO_WORK/profile" \
    --convert-to pdf --outdir projects/<name>/ projects/<name>/deck.pptx
```

- `soffice` and `libreoffice` are the same binary; either works.
- Output always lands in the active project folder: `projects/<name>/`.
- The output filename is the input's basename with the new extension.
- Run **one** conversion at a time per profile dir — a second concurrent run
  against the same `UserInstallation` will fail with a locking error. For a
  batch, pass multiple input files to a single command instead.

### Why the scratch dir lives on the volume, not /tmp
`/tmp`, `/var/log`, `/var/run` and `~/.cache` are `--tmpfs` (RAM-backed,
ephemeral, `/tmp` capped at 512 MB). The LibreOffice profile is throwaway, but
conversion spool files for large decks/workbooks can exceed the RAM cap and
compete with app memory. `${CLAUDE_HOME}/.cache/libreoffice` is on the
disk-backed `~/taskramen` bind mount — persistent across restarts and not
RAM-limited. (It is regenerable cache; safe to delete if a conversion hangs.)

## Supported conversions

LibreOffice opens any format below and exports to any other in the same row
(document↔document, sheet↔sheet, slide↔slide). **PDF is the universal target**
from every input.

| Family | Reads | Writes (`--convert-to`) |
|--------|-------|--------------------------|
| Word / text docs | `.docx .doc .odt .rtf .txt .html .fodt` | `pdf docx odt rtf txt html` |
| Spreadsheets | `.xlsx .xls .ods .csv .fods` | `pdf xlsx ods csv html` |
| Presentations | `.pptx .ppt .odp .fodp` | `pdf pptx odp` · `png`/`jpg` (one image per slide) |
| Drawings / vector | `.odg .vsd .svg .wmf` | `pdf svg png` |

Common invocations (same wrapper as above — shown bare for brevity):

```bash
soffice --headless --convert-to pdf      ...   report.docx     # Word  -> PDF
soffice --headless --convert-to pdf      ...   budget.xlsx     # Excel -> PDF
soffice --headless --convert-to pdf      ...   deck.pptx       # PPTX  -> PDF
soffice --headless --convert-to docx     ...   notes.odt       # ODF   -> Word
soffice --headless --convert-to 'csv:Text - txt - csv (StarCalc)' ... data.xlsx   # Excel -> CSV
soffice --headless --convert-to 'pdf:impress_pdf_Export' ...      deck.pptx       # explicit PDF filter
soffice --headless --convert-to png      --outdir slides/ deck.pptx   # slides -> images
```

## What LibreOffice does NOT do

- **Excel → Word is not a real conversion.** A spreadsheet and a text document
  have different models, so `xlsx --convert-to docx` produces garbage. To put
  spreadsheet data into a Word file, read it (`pandas`/`openpyxl`) and build a
  table with `python-docx` — see the `excel` and `word` skills. If you only need
  a read-only rendering, convert the `.xlsx` straight to **PDF** instead.
- **No editing.** LibreOffice here is convert-only; to *author* Office files use
  the `word`/`excel`/`powerpoint` skills, then convert the result.

## Troubleshooting

- **Hangs / "source file could not be loaded" / lock error:** a stale profile.
  `rm -rf "$LO_WORK/profile"` and retry — it is regenerated automatically.
- **"failed to create user installation" / read-only error:** the
  `-env:UserInstallation` flag is missing or points at the read-only `$HOME`.
  Always point it at `$LO_WORK/profile` on the volume as shown above.
- **Fonts look substituted:** only `fonts-liberation` is baked. Embedded fonts
  in the source render fine; for an exotic typeface, embed it in the source
  document before converting.
- **Verify the result:** check the output exists and has non-zero size, e.g.
  `ls -l projects/<name>/deck.pdf`; for a visual check, render page 1 with the
  `pdf` skill's pdfplumber/`pdftoppm` if available.
