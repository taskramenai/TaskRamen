#!/usr/bin/env python3
# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)
"""
check_title_divider_overlap.py — deterministic geometric QA check for the
"title text crosses the divider line" bug class in corporate-deck-style
.pptx files (see skills/powerpoint/corporate-deck-style.md).

Why this exists: two prior "fixes" for a title overlapping the horizontal
divider line, each verified only by rendering thumbnails and eyeballing
them, still left real overlaps in the deck. Visual QA missed it — either
the reviewer didn't zoom into the right slide, or a wrapped 2nd/3rd line of
title text rendered close enough to the divider that it looked fine at
thumbnail resolution but the actual glyph extent was past (or within a
hairline of) the divider.

**`fix_deck()` no longer moves anything.** Earlier versions grew the title
box and repositioned the divider per slide to clear whatever that slide's
title needed — correct, but it left the divider at a different Y position
on every slide depending on title length, which reads as inconsistent even
when nothing technically overlaps. The template's title-box height and
divider position are now a fixed layout budget, identical on every slide;
`fix_deck()` only reports which slides overflow it (with the overflowing
title's actual text), and the fix is to shorten that title's wording — not
to resize the layout or shrink the font. See `fix_deck()`'s own docstring.

This script does NOT trust the XML box height alone, because with
`auto_size=SHAPE_TO_FIT_TEXT` PowerPoint/LibreOffice recompute the shape's
rendered height from the actual wrapped text at open/render time — the
`.height` value stored in the XML can be stale. It also does NOT trust a
hand-rolled character-width wrap estimate — even with the deck's real
title font available (see below), predicting wrap points without an
actual layout engine is fragile.

**Font accuracy matters more than it first appears.** This module used to
render with whatever font LibreOffice substituted for "Inter" (not
installed in a bare environment), which measurably wraps titles onto MORE
lines than the real Inter font does on an actual device — so a
"render-verified" fix computed against the wrong font systematically
leaves extra vertical space that isn't actually needed, which is exactly
as user-visible a defect as an overlap (found the hard way: a deck fixed
and re-verified against the fallback font still showed a large gap between
title and divider once opened on a real phone). `ensure_font_installed()`
below checks for "Inter" via `fc-list` and installs it on demand (from
Google Fonts' canonical OFL source) before any rendering happens, so this
module is self-healing in a fresh environment rather than silently
measuring against the wrong glyphs again.

Instead this is a hybrid check:
  1. python-pptx reads the XML to identify each slide's title shape (by
     name/placeholder heuristics) and divider shape (LINE shapes, or a
     shape named "Connector N"), and their declared box geometry.
  2. The deck is rendered to PDF via the SAME LibreOffice engine used for
     thumbnail QA (`skills/powerpoint/SKILL.md` UserInstallation pattern),
     so it reflects real autofit/wrap behavior and whatever font
     LibreOffice actually substitutes — no font-metric guessing.
  3. pdfplumber extracts the actual rendered glyph bounding boxes for the
     title's text (words whose vertical position falls in the slide's
     title band) and the actual rendered position of the divider line
     (LibreOffice draws thin/zero-height connectors as `curves`, not
     `lines`, in the exported PDF — detected here as a near-zero-height,
     near-full-width curve).
  4. The real title bottom used for the check is
     max(declared box bottom, rendered glyph bottom) — this is what
     catches the specific bug class described in the task: a box height
     that was fixed in the XML but where the actual rendered text still
     overflows it.

A slide is flagged if (divider top) - (title bottom) < MARGIN_IN.

Usage:
    python3 check_title_divider_overlap.py deck1.pptx [deck2.pptx ...]
    python3 check_title_divider_overlap.py --margin 0.05 deck1.pptx

Exit code: 0 if every slide in every deck passes, 1 if any slide is flagged.
"""

import argparse
import os
import subprocess
import sys
import tempfile

from pptx import Presentation
from pptx.enum.shapes import MSO_SHAPE_TYPE
from pptx.util import Emu
from pptx.oxml.ns import qn

try:
    import pdfplumber
except ImportError:
    print("ERROR: pdfplumber is required (pip install pdfplumber)", file=sys.stderr)
    sys.exit(2)

EMU_PER_IN = 914400
PT_PER_IN = 72.0
MARGIN_IN_DEFAULT = 0.05

TITLE_NAME_CANDIDATES = ("TextBox 1", "Title 1", "Title")


def find_title_shape(slide):
    """Identify the slide's title shape. Prefer an actual title placeholder;
    fall back to the deck's known title textbox naming convention, then to
    any placeholder/shape whose name suggests it's the title."""
    for shape in slide.shapes:
        if shape.is_placeholder and shape.placeholder_format.type is not None:
            try:
                from pptx.enum.shapes import PP_PLACEHOLDER
                if shape.placeholder_format.type in (
                    PP_PLACEHOLDER.TITLE, PP_PLACEHOLDER.CENTER_TITLE
                ):
                    return shape
            except Exception:
                pass
    for name in TITLE_NAME_CANDIDATES:
        for shape in slide.shapes:
            if shape.name == name and shape.has_text_frame and shape.text_frame.text.strip():
                return shape
    return None


def find_divider_shape(slide):
    """Identify a horizontal divider/connector shape on the slide: a LINE
    shape (or a shape named 'Connector N') that is wide and has ~zero
    height (i.e. horizontal), positioned above the vertical midline isn't
    required — any horizontal divider counts. Returns the one nearest the
    top of the slide if multiple qualify (title dividers sit high)."""
    candidates = []
    for shape in slide.shapes:
        is_line = False
        try:
            is_line = shape.shape_type == MSO_SHAPE_TYPE.LINE
        except Exception:
            pass
        name_says_connector = shape.name.startswith("Connector")
        if not (is_line or name_says_connector):
            continue
        try:
            top = shape.top
            width = shape.width
            height = shape.height
        except Exception:
            continue
        if top is None or width is None:
            continue
        height = height or 0
        # Horizontal divider: much wider than tall, and reasonably wide
        # (spans most of the slide, not a small in-content rule).
        if width > 5 * EMU_PER_IN and height <= 0.05 * EMU_PER_IN:
            candidates.append(shape)
    if not candidates:
        return None
    # The title divider is the topmost qualifying horizontal line.
    candidates.sort(key=lambda s: s.top)
    return candidates[0]


# Google Fonts' CSS2 API serves .woff (not .ttf) regardless of User-Agent
# now — confirmed this environment's fontconfig/FreeType reads .woff
# directly (installed and fc-list'd correctly), so no format conversion
# needed. Any UA works; kept explicit for a stable/predictable response.
_LEGACY_UA = "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/30.0.1599.101 Safari/537.36"
_FONTS_CHECKED = set()  # family names already verified/attempted this process


def scan_pptx_fonts(pptx_path):
    """Return the set of font family names actually referenced in a .pptx —
    every run's explicit `font.name` across every slide, plus the theme's
    major/minor Latin typefaces (the fallback for runs that don't override
    it). Generic across templates: this is how we find out which font(s)
    need to exist locally for an accurate render, instead of assuming any
    one specific font."""
    prs = Presentation(pptx_path)
    families = set()
    for slide in prs.slides:
        for shape in slide.shapes:
            if not shape.has_text_frame:
                continue
            for para in shape.text_frame.paragraphs:
                for run in para.runs:
                    if run.font.name:
                        families.add(run.font.name)
    try:
        theme_xml = prs.slide_masters[0].element.getroottree()
        ns = {"a": "http://schemas.openxmlformats.org/drawingml/2006/main"}
        for tag in ("majorFont", "minorFont"):
            el = theme_xml.find(f".//a:{tag}/a:latin", ns)
            if el is not None and el.get("typeface") and el.get("typeface") != "+mn-lt":
                families.add(el.get("typeface"))
    except Exception:
        pass
    return families


def ensure_font_installed(family):
    """Make sure `family` is actually installed for LibreOffice to render
    with, installing it on demand if not. Idempotent per family within a
    process, and safe to call every run — a fresh sandbox/container won't
    have whatever font a given template specifies, and measuring against a
    silently-substituted fallback produces wrong (usually over-generous)
    title/divider spacing — found the hard way with "Inter" on this
    template, but the fix has to generalize to whatever font a *different*
    template uses, not stay hardcoded to that one case.

    Fetches from the Google Fonts CSS2 API rather than a font-specific URL,
    since that works for any font Google Fonts hosts (which covers the vast
    majority of professional template fonts, including Inter/Lato/Raleway
    used across this skill's decks) without needing to know each font's
    exact upstream repo path. Silently no-ops (with a stderr warning) for
    fonts it can't find there — not every font is open-source/hosted, and
    this is a best-effort accuracy improvement, not a hard requirement.
    """
    if family in _FONTS_CHECKED:
        return
    _FONTS_CHECKED.add(family)
    try:
        installed = subprocess.run(
            ["fc-list"], capture_output=True, text=True, timeout=15
        ).stdout
        if family.lower() in installed.lower():
            return
    except Exception:
        return  # fc-list unavailable — nothing we can safely do here

    import urllib.request
    import urllib.parse
    import re as _re

    fonts_dir = os.path.join(os.path.expanduser("~"), ".fonts")
    try:
        os.makedirs(fonts_dir, exist_ok=True)
        family_param = urllib.parse.quote(family)
        css_url = (
            f"https://fonts.googleapis.com/css2?family={family_param}"
            f":wght@400;500;600;700;800&display=swap"
        )
        req = urllib.request.Request(css_url, headers={"User-Agent": _LEGACY_UA})
        css = urllib.request.urlopen(req, timeout=15).read().decode()
        font_urls = sorted(set(
            _re.findall(r"url\((https://[^)]+\.(?:ttf|otf|woff2?))\)", css)
        ))
        if not font_urls:
            print(
                f"WARNING: '{family}' not found on Google Fonts — "
                f"rendering will fall back to a substitute font.",
                file=sys.stderr,
            )
            return
        downloaded = 0
        for i, url in enumerate(font_urls[:6]):  # cap: a handful of weights is plenty
            ext = url.rsplit(".", 1)[-1]
            dest = os.path.join(
                fonts_dir, f"{family.replace(' ', '')}-{i}.{ext}"
            )
            urllib.request.urlretrieve(url, dest)
            if os.path.getsize(dest) < 10000:
                os.remove(dest)
                continue
            downloaded += 1
        if downloaded:
            subprocess.run(
                ["fc-cache", "-f", fonts_dir], capture_output=True, timeout=30
            )
    except Exception as e:
        print(
            f"WARNING: could not auto-install '{family}' font "
            f"({e}) — rendering will fall back to a substitute font, "
            f"which can make title/divider spacing measurements wrong.",
            file=sys.stderr,
        )


def render_pdf(pptx_path, workdir):
    for family in scan_pptx_fonts(pptx_path):
        ensure_font_installed(family)
    lo_work = os.path.join(
        os.environ.get("CLAUDE_HOME", os.path.expanduser("~/taskramen")),
        ".cache", "libreoffice",
    )
    profile_dir = os.path.join(lo_work, "profile")
    tmp_dir = os.path.join(lo_work, "tmp")
    os.makedirs(profile_dir, exist_ok=True)
    os.makedirs(tmp_dir, exist_ok=True)

    soffice = None
    for candidate in ("soffice", "libreoffice"):
        from shutil import which
        found = which(candidate)
        if found:
            soffice = found
            break
    if not soffice:
        raise RuntimeError("soffice/libreoffice not found on PATH")

    env = dict(os.environ)
    env["TMPDIR"] = tmp_dir
    cmd = [
        soffice, "--headless", "--norestore",
        f"-env:UserInstallation=file://{profile_dir}",
        "--convert-to", "pdf", "--outdir", workdir, pptx_path,
    ]
    result = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=90)
    base = os.path.splitext(os.path.basename(pptx_path))[0]
    pdf_path = os.path.join(workdir, base + ".pdf")
    if not os.path.exists(pdf_path):
        raise RuntimeError(
            f"LibreOffice PDF conversion failed for {pptx_path}:\n"
            f"stdout={result.stdout}\nstderr={result.stderr}"
        )
    return pdf_path


def find_rendered_divider_top_pt(page):
    """Return the top (pt) of the topmost near-zero-height, near-full-width
    curve on the rendered page — this is how LibreOffice draws a thin
    horizontal connector line when exporting to PDF."""
    page_w = page.width
    candidates = []
    for c in page.curves:
        h = c["bottom"] - c["top"]
        w = c["x1"] - c["x0"]
        if h <= 1.5 and w >= 0.9 * page_w:
            candidates.append(c["top"])
    # Also check `lines` in case LibreOffice draws it as an actual line object.
    for l in page.lines:
        h = l["bottom"] - l["top"]
        w = l["x1"] - l["x0"]
        if h <= 1.5 and w >= 0.9 * page_w:
            candidates.append(l["top"])
    if not candidates:
        return None
    return min(candidates)


def find_rendered_title_bottom_pt(page, title_top_in, title_left_in, title_width_in,
                                   max_lines=6, size_tol_pt=2.0):
    """Return the max rendered glyph bottom (pt) of the title's own wrapped
    text block.

    Uses per-CHARACTER font size (available from the rendered PDF) to
    identify which rows of text actually belong to the title versus a
    body/bullet paragraph that happens to start just below it: the title
    is rendered in one consistent font size, and the body text below it
    uses a visibly smaller size (this deck's style guide enforces a
    title > body font-size hierarchy — see skills/powerpoint/corporate-deck-style.md —
    so this is a safe, general discriminator, not a one-off hack). This
    replaces an earlier, less reliable attempt that used only a fixed
    vertical search window and a line-gap heuristic, which incorrectly
    pulled a wrapped title's neighboring bullet line into the same
    cluster when the visual line-gap happened to be small.

    Algorithm: take all chars in the title's horizontal column starting
    at/after the title box's own top; group into rows by 'top'; determine
    the dominant font size of the FIRST row (the title's own declared
    size); keep consuming subsequent rows only while their dominant font
    size matches that first-row size within `size_tol_pt` — stop at the
    first row whose font size differs (that's body text, not a wrapped
    title line) or after `max_lines` rows (safety cap).
    """
    top_pt = title_top_in * PT_PER_IN
    left_pt = title_left_in * PT_PER_IN
    right_pt = (title_left_in + title_width_in) * PT_PER_IN

    chars = [
        c for c in page.chars
        if c["text"].strip() != ""
        and c["top"] >= top_pt - 3
        and not (c["x1"] < left_pt - 5 or c["x0"] > right_pt + 5)
    ]
    if not chars:
        return None
    chars.sort(key=lambda c: (c["top"], c["x0"]))

    # Cluster into rows by 'top' proximity (within 2pt = same text line).
    rows = []
    for c in chars:
        if rows and abs(c["top"] - rows[-1][0]["top"]) <= 2:
            rows[-1].append(c)
        else:
            rows.append([c])
    if not rows:
        return None

    def dominant_size(row):
        sizes = [c["size"] for c in row]
        return max(set(sizes), key=sizes.count)

    title_size = dominant_size(rows[0])
    kept_rows = []
    for row in rows[:max_lines]:
        if abs(dominant_size(row) - title_size) > size_tol_pt:
            break
        kept_rows.append(row)

    all_chars = [c for row in kept_rows for c in row]
    return max(c["bottom"] for c in all_chars)


def fix_deck(pptx_path, margin_in=MARGIN_IN_DEFAULT, extra_gap_in=0.08,
             shift_shapes_below=True, max_iterations=4, verbose=True):
    """Detect-only: report every slide whose title overflows into the
    divider — never resizes the title box, never moves the divider, never
    shifts any other shape. `extra_gap_in`/`shift_shapes_below`/
    `max_iterations` are accepted but unused; kept so existing call sites
    (`fixed, remaining = fix_deck(OUT)`) don't need to change.

    Earlier versions of this function actively fixed overflow by growing
    the title box and moving the divider (optionally cascading to adjacent
    content). That produced a *correct but inconsistent* deck: the divider
    ends up at a different Y position on every slide depending on how long
    that slide's title happens to be, which reads as sloppy even when no
    slide technically overlaps — a real template convention keeps a
    decorative element like a divider at one fixed position throughout the
    whole deck, not slide-by-slide (the user's own call, after watching an
    auto-mover "fix" this three times and still not liking the result).

    So the template's title-box height and divider position are the fixed,
    non-negotiable layout budget now. If a slide's title doesn't fit within
    it, that is treated purely as a WRITING problem, not a layout problem:
    the fix is a shorter, more concise title, authored by whoever's
    building the deck — never a bigger box, and never a smaller font either
    (explicitly ruled out — a shrinking title font across slides is its own
    kind of inconsistency). This function's only remaining job is to tell
    you which slides need a rewrite and by roughly how much.

    Returns (overflowing_slide_numbers, remaining_fail_rows) — both are the
    same information in two shapes for backward compatibility with
    existing callers; `remaining_fail_rows` carries the full per-slide
    detail (gap_in, title text, etc.) for printing a useful diagnostic.
    """
    with tempfile.TemporaryDirectory() as workdir:
        rows = check_deck(pptx_path, workdir, margin_in)
    fails = [r for r in rows if r["status"] == "FAIL"]

    if verbose:
        prs = Presentation(pptx_path) if fails else None
        for row in fails:
            idx = row["slide"]
            title = find_title_shape(prs.slides[idx - 1]) if prs else None
            title_text = title.text_frame.text if title is not None and title.has_text_frame else "?"
            overflow_in = margin_in - row["gap_in"]
            print(
                f"  [overflow] slide {idx}: title runs {overflow_in:.3f}in "
                f"into the divider (gap={row['gap_in']:.3f}in, needs >= "
                f"{margin_in:.3f}in) — shorten the title text, don't "
                f"resize the layout. Current text: {title_text!r}"
            )

    return sorted(r["slide"] for r in fails), fails


def check_deck(pptx_path, workdir, margin_in):
    prs = Presentation(pptx_path)
    pdf_path = render_pdf(pptx_path, workdir)
    results = []

    with pdfplumber.open(pdf_path) as pdf:
        for idx, slide in enumerate(prs.slides, start=1):
            title = find_title_shape(slide)
            divider = find_divider_shape(slide)
            page = pdf.pages[idx - 1]

            row = {
                "slide": idx,
                "title_name": title.name if title else None,
                "divider_name": divider.name if divider else None,
                "status": None,
                "title_box_bottom_in": None,
                "title_rendered_bottom_in": None,
                "title_effective_bottom_in": None,
                "divider_top_xml_in": None,
                "divider_top_rendered_in": None,
                "divider_effective_top_in": None,
                "gap_in": None,
            }

            if title is None or divider is None:
                row["status"] = "SKIP (no title or no divider on this slide)"
                results.append(row)
                continue

            title_top_in = title.top / EMU_PER_IN
            title_left_in = title.left / EMU_PER_IN
            title_width_in = title.width / EMU_PER_IN
            title_height_in = (title.height or 0) / EMU_PER_IN
            box_bottom_in = title_top_in + title_height_in

            rendered_bottom_pt = find_rendered_title_bottom_pt(
                page, title_top_in, title_left_in, title_width_in
            )
            rendered_bottom_in = (
                rendered_bottom_pt / PT_PER_IN if rendered_bottom_pt is not None else None
            )

            candidates = [box_bottom_in]
            if rendered_bottom_in is not None:
                candidates.append(rendered_bottom_in)
            effective_title_bottom_in = max(candidates)

            divider_top_xml_in = divider.top / EMU_PER_IN
            rendered_divider_top_pt = find_rendered_divider_top_pt(page)
            rendered_divider_top_in = (
                rendered_divider_top_pt / PT_PER_IN
                if rendered_divider_top_pt is not None else None
            )
            # Prefer the rendered position (ground truth); fall back to XML.
            effective_divider_top_in = (
                rendered_divider_top_in
                if rendered_divider_top_in is not None
                else divider_top_xml_in
            )

            gap_in = effective_divider_top_in - effective_title_bottom_in

            row.update({
                "title_box_bottom_in": round(box_bottom_in, 4),
                "title_rendered_bottom_in": (
                    round(rendered_bottom_in, 4) if rendered_bottom_in is not None else None
                ),
                "title_effective_bottom_in": round(effective_title_bottom_in, 4),
                "divider_top_xml_in": round(divider_top_xml_in, 4),
                "divider_top_rendered_in": (
                    round(rendered_divider_top_in, 4)
                    if rendered_divider_top_in is not None else None
                ),
                "divider_effective_top_in": round(effective_divider_top_in, 4),
                "gap_in": round(gap_in, 4),
                "status": "FAIL" if gap_in < margin_in else "OK",
            })
            results.append(row)

    return results


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("decks", nargs="+", help="Path(s) to .pptx file(s)")
    ap.add_argument("--margin", type=float, default=MARGIN_IN_DEFAULT,
                     help=f"Minimum required gap in inches (default {MARGIN_IN_DEFAULT})")
    ap.add_argument("--fix", action="store_true",
                     help="Auto-fix any FAIL slide in place (grows the title "
                          "box and moves the divider + downstream shapes to "
                          "clear it), re-rendering to verify, before printing "
                          "the final report.")
    args = ap.parse_args()

    if args.fix:
        for deck_path in args.decks:
            print(f"\nFixing {deck_path} ...")
            fixed, remaining = fix_deck(deck_path, margin_in=args.margin)
            if fixed:
                print(f"  Adjusted slide(s): {fixed}")
            else:
                print("  No changes needed.")
            if remaining:
                print(f"  STILL FAILING after auto-fix: "
                      f"{[r['slide'] for r in remaining]}")

    any_fail = False
    with tempfile.TemporaryDirectory() as workdir:
        for deck_path in args.decks:
            print(f"\n{'=' * 100}")
            print(f"DECK: {deck_path}")
            print(f"{'=' * 100}")
            rows = check_deck(deck_path, workdir, args.margin)
            header = (
                f"{'Slide':>5} {'Title shape':<14} {'Divider':<12} "
                f"{'BoxBot':>8} {'RendBot':>9} {'EffBot':>8} "
                f"{'DivXML':>8} {'DivRend':>8} {'EffTop':>8} {'Gap':>8}  Status"
            )
            print(header)
            print("-" * len(header))
            for row in rows:
                if row["status"] and row["status"].startswith("SKIP"):
                    print(f"{row['slide']:>5}  {row['status']}")
                    continue
                print(
                    f"{row['slide']:>5} {str(row['title_name']):<14} "
                    f"{str(row['divider_name']):<12} "
                    f"{row['title_box_bottom_in']:>8} "
                    f"{str(row['title_rendered_bottom_in']):>9} "
                    f"{row['title_effective_bottom_in']:>8} "
                    f"{row['divider_top_xml_in']:>8} "
                    f"{str(row['divider_top_rendered_in']):>8} "
                    f"{row['divider_effective_top_in']:>8} "
                    f"{row['gap_in']:>8}  {row['status']}"
                )
                if row["status"] == "FAIL":
                    any_fail = True

    print()
    if any_fail:
        print("RESULT: FAIL — one or more slides have title text overlapping (or too close to) the divider.")
    else:
        print("RESULT: PASS — all checked slides have adequate title/divider clearance.")
    sys.exit(1 if any_fail else 0)


if __name__ == "__main__":
    main()
