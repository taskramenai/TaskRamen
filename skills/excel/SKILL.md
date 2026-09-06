# Excel Skill (.xlsx)

Create, read, and edit Microsoft Excel workbooks locally with **openpyxl**
(MIT-licensed). Use for any request mentioning a "spreadsheet", "workbook",
"Excel", or a `.xlsx` file. For pure data analysis, **pandas** pairs well
(both are pre-installed); for formatting and formulas, use openpyxl directly.

## Setup
`openpyxl` and `pandas` are pre-installed in the container image — no install step needed.
```bash
# Only if running outside the container (e.g. a bare host):
#   pip install --quiet openpyxl pandas
```
To recalculate formulas or convert to PDF, LibreOffice is pre-installed → see `skills/libreoffice/SKILL.md`.

## Where files go
Always write to the active project folder: `projects/<name>/`.

## Golden rule: write FORMULAS, not hardcoded results
Put real Excel formulas in cells (`="=SUM(B2:B13)"`) so the workbook stays live and
auditable. Do NOT compute a number in Python and paste the static value, unless the
user explicitly wants a values-only export.

## Reading a workbook
```bash
python3 - <<'PY'
import openpyxl
wb = openpyxl.load_workbook("projects/<name>/book.xlsx", data_only=True)  # data_only=cached values
for ws in wb.worksheets:
    print("##", ws.title)
    for row in ws.iter_rows(values_only=True):
        print(row)
PY
```
Note: `data_only=True` returns the last value Excel/LibreOffice cached. A file written
by openpyxl has no cached values until it's been opened/recalculated once (see recalc below).

## Creating a workbook
Use `skills/excel/example.py` as a starting template. Core pattern:
```python
import openpyxl
from openpyxl.styles import Font, PatternFill, numbers

wb = openpyxl.Workbook()
ws = wb.active
ws.title = "P&L"
ws.append(["Month", "Revenue", "Costs", "Profit"])
for r, (m, rev, cost) in enumerate([("Jan", 12000, 8000), ("Feb", 14500, 8200)], start=2):
    ws.cell(r, 1, m)
    ws.cell(r, 2, rev)
    ws.cell(r, 3, cost)
    ws.cell(r, 4, f"=B{r}-C{r}")          # formula, not a precomputed number
ws["B4"] = "=SUM(B2:B3)"
for c in "BCD":                            # currency format
    for cell in ws[c]:
        cell.number_format = '#,##0;(#,##0)'
for cell in ws[1]:                         # bold header
    cell.font = Font(bold=True)
wb.save("projects/<name>/book.xlsx")
```

## Editing an existing workbook
`load_workbook(path)` (without `data_only`) preserves formulas and most formatting,
mutate cells, then `save`. Save to a new filename if you must keep the original intact.

## Recalculating formulas (so cached values exist)
openpyxl does not evaluate formulas. To produce a file with computed values (e.g. before
charting from results or exporting to PDF), recalc once via LibreOffice headless:
```bash
libreoffice --headless --calc --convert-to xlsx --outdir projects/<name>/ projects/<name>/book.xlsx
```
Then reopen with `data_only=True` to read results.

## Formatting conventions (financial models)
- Number formats: currency `#,##0;(#,##0)` (negatives in parentheses), percentages `0.0%`,
  years as text (`"2024"`), show zeros as `-` with format `#,##0;-#,##0;"-"`.
- Color convention many finance teams expect: blue font for hardcoded inputs,
  black for formulas, so reviewers can see what's editable.
- Document any hardcoded assumption with a cell comment naming its source and date.
- Keep fonts consistent; freeze the header row (`ws.freeze_panes = "A2"`).

## QA before delivering
1. Reopen and scan for `#REF!`, `#DIV/0!`, `#VALUE!`, `#NAME?` — fix any.
2. Recalc via LibreOffice and confirm totals look right.
3. Send the `.xlsx` via the file-send tool.
