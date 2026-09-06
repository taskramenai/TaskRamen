#!/usr/bin/env python3
# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)
"""Starter template for building a PDF from scratch with reportlab (BSD-licensed).

Copy into the active project folder and adapt. Run:
    pip install --quiet reportlab
    python3 example.py
Produces invoice.pdf in the same folder.
"""
import sys
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle
from reportlab.lib import colors
from reportlab.lib.units import cm

OUT = sys.argv[1] if len(sys.argv) > 1 else "invoice.pdf"
styles = getSampleStyleSheet()

doc = SimpleDocTemplate(OUT, pagesize=A4, title="Invoice")
story = [
    Paragraph("Invoice #1042", styles["Title"]),
    Spacer(1, 0.3 * cm),
    Paragraph("Acme Pte Ltd  -  13 Jun 2026", styles["Normal"]),
    Spacer(1, 0.6 * cm),
]

rows = [
    ["Item", "Qty", "Amount (USD)"],
    ["Marketing analytics", "1 mo", "1,200"],
    ["Ad management", "1 mo", "400"],
    ["Total", "", "1,600"],
]
table = Table(rows, colWidths=[9 * cm, 3 * cm, 4 * cm])
table.setStyle(TableStyle([
    ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#1F49E0")),
    ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
    ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
    ("FONTNAME", (0, -1), (-1, -1), "Helvetica-Bold"),
    ("ALIGN", (1, 0), (-1, -1), "RIGHT"),
    ("GRID", (0, 0), (-1, -1), 0.5, colors.grey),
    ("ROWBACKGROUNDS", (0, 1), (-1, -2), [colors.white, colors.HexColor("#F2F5FF")]),
]))
story.append(table)

doc.build(story)
print(f"Wrote {OUT}")
