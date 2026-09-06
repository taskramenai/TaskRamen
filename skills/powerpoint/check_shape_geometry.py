#!/usr/bin/env python3
# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)
"""
check_shape_geometry.py — deterministic geometric QA checks for two failure
classes from skills/powerpoint/corporate-deck-style.md: "Boundary overflow" and
"Cross-shape alignment" (see that doc for full rationale/fix guidance).

Why this exists: a real deck shipped with picture/text-column pairs whose
`top` coordinates didn't match (the picture placeholder authored flush with
the slide's top margin, the paired body-text placeholder authored lower,
below that slide's own title) — invisible from reading the XML/text alone,
only obvious once rendered. This script makes both checks mechanical instead
of relying on a human to notice a fraction-of-an-inch mismatch in a
thumbnail image.

Two checks, both pure shape-geometry (no text-measurement/rendering needed,
unlike check_title_divider_clearance.py's overlap check):

1. BOUNDARY OVERFLOW — for every shape on every slide, `shape.left +
   shape.width` must be <= `prs.slide_width` and `shape.top + shape.height`
   must be <= `prs.slide_height` (each with a small tolerance for float/EMU
   rounding). A shape that fails is spilling off the edge of the slide.
   This extends the title/divider-only overflow check
   (check_title_divider_clearance.py) to every other content box.

2. CROSS-SHAPE ALIGNMENT — for every PICTURE shape on a slide, finds the
   non-title content shape with the least horizontal overlap with it (i.e.
   the shape most clearly "the other side of the row") among shapes tall
   enough to be a real content column (>= MIN_COLUMN_HEIGHT_IN, which
   excludes short title/kicker/footer bands that share a column with the
   real content block but were never meant to align with the picture) and
   flags the pair if their `top` values differ by more than the tolerance.
   This is a heuristic for "this picture and this text column are meant to
   be a side-by-side row" — genuine false positives are possible for decks
   that deliberately stagger columns; use judgment on any FAIL this prints,
   the same way check_title_divider_clearance.py's SKIP rows require
   judgment about which shape is really "the title."

**What this script deliberately does NOT check:** the "Underfill check"
rule (a top-anchored box with dead space below its actual text) needs real
text measurement — where the wrapped text actually ends inside the box —
which requires either a rendering engine (LibreOffice, as
check_title_divider_clearance.py uses for its title-overflow check) or
font-metric text-layout code this repo doesn't have. Reusing this box's
declared height/position alone can't tell you how much of it the text
actually fills. That check stays a manual/visual QA step (thumbnail render
+ look at the gap below the last line) per skills/powerpoint/SKILL.md's
"large unused empty space" guidance — not mechanized here to avoid a
fragile, invented text-wrap estimate.

Usage:
    python3 check_shape_geometry.py deck1.pptx [deck2.pptx ...]
    python3 check_shape_geometry.py --tolerance-in 0.05 deck.pptx

Exit code 0 = no FAILs (both checks), non-zero = at least one FAIL.
"""
import argparse
import sys

from pptx import Presentation
from pptx.util import Emu

EMU_PER_IN = 914400

# Default tolerances, in inches. Overflow tolerance absorbs EMU/float
# rounding noise (real overflow is visually obvious well past this).
# Alignment tolerance absorbs the same kind of rounding plus genuinely
# hairline authoring differences that aren't visually perceptible.
DEFAULT_OVERFLOW_TOLERANCE_IN = 0.02
DEFAULT_ALIGN_TOLERANCE_IN = 0.05

# Minimum horizontal overlap (as a fraction of the narrower shape's width)
# for two shapes to NOT be considered "side by side columns" — i.e. if two
# shapes overlap horizontally by more than this fraction, they're probably
# stacked vertically (e.g. a title above a body), not side-by-side, and are
# skipped by the alignment check.
MAX_HORIZONTAL_OVERLAP_FRACTION = 0.3

# Shape kinds excluded from both checks entirely: decorative/background
# elements and things that legitimately live at/near slide edges (page
# numbers, logos) shouldn't be flagged as if they were content boxes.
SKIP_NAME_SUBSTRINGS = ("slide number", "page number", "logo", "watermark")

# Minimum height (in) for a text/content shape to be considered a candidate
# "column" for the alignment check — excludes short bands (titles, kicker/
# eyebrow placeholders, footers) that share a column with a real content
# block but were never meant to align with a picture on the other side.
MIN_COLUMN_HEIGHT_IN = 2.0

# "Half-width title" threshold, as a fraction of slide width — see
# skills/powerpoint/corporate-deck-style.md's "half-width title" refinement to the
# cross-shape-alignment rule. On slides where the title placeholder is
# deliberately authored at less than this fraction of the slide's width
# (a picture occupies the other half, stacked beside a title+bullets
# column), the expected picture geometry is different from the general
# case: instead of the picture's `top` matching the BODY column's `top`,
# it should match the TITLE's `top` (and the picture's bottom should reach
# down to the body column's bottom, spanning the full title-to-bullets
# height) — the picture is meant to run the full height of that two-column
# region, not just align with where the bullets start. Comfortably above
# 0.5 (an exact half) to absorb authoring slop, but still well under a
# full-width title (which is what the general case assumes).
HALF_WIDTH_TITLE_FRACTION = 0.55

# python-pptx MSO_SHAPE_TYPE.PICTURE value (avoids importing the enum just
# for one comparison).
_PICTURE_SHAPE_TYPE = 13


def _shape_bounds(shape):
    if shape.left is None or shape.top is None or shape.width is None or shape.height is None:
        return None
    return (shape.left, shape.top, shape.left + shape.width, shape.top + shape.height)


def _is_skippable(shape):
    name = (shape.name or "").lower()
    return any(sub in name for sub in SKIP_NAME_SUBSTRINGS)


def check_boundary_overflow(prs, tolerance_in):
    tol = Emu(int(tolerance_in * EMU_PER_IN))
    sw, sh = prs.slide_width, prs.slide_height
    rows = []
    for i, slide in enumerate(prs.slides, 1):
        for shape in slide.shapes:
            if _is_skippable(shape):
                continue
            bounds = _shape_bounds(shape)
            if bounds is None:
                continue
            left, top, right, bottom = bounds
            over_right = right - sw
            over_bottom = bottom - sh
            over_left = -left
            over_top = -top
            worst = max(over_right, over_bottom, over_left, over_top)
            if worst > tol:
                rows.append({
                    "slide": i,
                    "shape": shape.name,
                    "over_right_in": round(over_right / EMU_PER_IN, 3),
                    "over_bottom_in": round(over_bottom / EMU_PER_IN, 3),
                    "over_left_in": round(over_left / EMU_PER_IN, 3),
                    "over_top_in": round(over_top / EMU_PER_IN, 3),
                    "status": "FAIL",
                })
    return rows


def _horizontal_overlap_fraction(a, b):
    """Fraction of the narrower shape's width that overlaps horizontally."""
    a_left, _, a_right, _ = a
    b_left, _, b_right, _ = b
    overlap = min(a_right, b_right) - max(a_left, b_left)
    if overlap <= 0:
        return 0.0
    narrower_width = min(a_right - a_left, b_right - b_left)
    if narrower_width <= 0:
        return 0.0
    return overlap / narrower_width


def check_cross_shape_alignment(prs, tolerance_in):
    """Flags a picture and its paired content column when their `top`s
    don't match. Deliberately narrow (pictures vs. the single largest
    non-title content column, not every possible shape pair) to avoid
    false positives from a slide's title/kicker bands, which legitimately
    share a horizontal column with the body text without being "paired"
    with the picture the way the body text is.

    HALF-WIDTH TITLE CASE (skills/powerpoint/corporate-deck-style.md's refinement to
    this rule): when the slide's title placeholder is itself narrow — under
    HALF_WIDTH_TITLE_FRACTION of the slide width — that's a deliberate
    two-column layout where a picture occupies the other half, stacked
    beside the title+bullets column. On these slides the picture is meant
    to be aspect-fit into a box that spans from the TITLE's `top` down to
    the body column's `bottom` (the full title-to-bullets column height),
    not just top-aligned with where the bullets start. Because aspect-ratio
    preservation legitimately leaves symmetric centering slack when the
    image's own ratio doesn't exactly match that box's ratio (e.g. a 4:3
    landscape photo centered in a taller, narrower box), the check here is
    NOT "does the picture's top/bottom touch the span's edges exactly" —
    that would false-positive on every correctly-fit landscape image. It's
    instead: is the picture vertically CENTERED within that span (top-gap
    ~= bottom-gap, within tolerance)? That still catches a genuine
    regression (e.g. only top-aligned with no bottom extension at all,
    which would show a near-zero top gap and a huge bottom gap) while
    accepting the expected, symmetric aspect-fit slack. A slide with a
    half-width title but no paired body column (e.g. a single merged
    title+narrative text block with nothing else to compare against, no
    separate "bullets box" at all) has nothing to define the span with and
    is skipped."""
    tol = Emu(int(tolerance_in * EMU_PER_IN))
    rows = []
    for i, slide in enumerate(prs.slides, 1):
        pictures = []
        columns = []
        title_bounds = None
        for shape in slide.shapes:
            if _is_skippable(shape):
                continue
            bounds = _shape_bounds(shape)
            if bounds is None:
                continue
            if shape.shape_type == _PICTURE_SHAPE_TYPE:
                pictures.append((shape, bounds))
                continue
            is_title = shape.is_placeholder and shape.placeholder_format.idx == 0
            if is_title:
                title_bounds = bounds
                continue
            if (shape.height / EMU_PER_IN) < MIN_COLUMN_HEIGHT_IN:
                continue
            columns.append((shape, bounds))

        half_width_title = (
            title_bounds is not None
            and (title_bounds[2] - title_bounds[0]) < HALF_WIDTH_TITLE_FRACTION * prs.slide_width
        )

        for pic_shape, pic_bounds in pictures:
            # Pick the column with the LEAST horizontal overlap with this
            # picture (i.e. the one most clearly "the other side of the
            # row"), among columns with only minor overlap.
            best = None
            best_overlap = None
            for col_shape, col_bounds in columns:
                overlap = _horizontal_overlap_fraction(pic_bounds, col_bounds)
                if overlap > MAX_HORIZONTAL_OVERLAP_FRACTION:
                    continue
                if best_overlap is None or overlap < best_overlap:
                    best, best_overlap = (col_shape, col_bounds), overlap
            if best is None:
                continue
            col_shape, col_bounds = best
            pic_top = pic_bounds[1]

            if half_width_title:
                # Expected span: title's top down to the body column's
                # bottom. Check the picture is vertically CENTERED within
                # that span (top-gap ~= bottom-gap), not that it touches
                # both edges exactly — aspect-ratio-preserving fit
                # legitimately leaves symmetric slack when the image's own
                # ratio doesn't match the span's box ratio (see docstring).
                span_top, span_bottom = title_bounds[1], col_bounds[3]
                pic_bottom = pic_bounds[3]
                top_gap = pic_top - span_top
                bottom_gap = span_bottom - pic_bottom
                # Genuine misalignment: either gap is negative (picture
                # spills outside the intended span) or the two gaps differ
                # by more than tolerance (asymmetric — e.g. still only
                # aligned to the old body.top reference, which would show
                # a near-zero top gap alongside a large bottom gap).
                if top_gap < -tol or bottom_gap < -tol or abs(top_gap - bottom_gap) > tol:
                    rows.append({
                        "slide": i,
                        "shape_a": pic_shape.name,
                        "shape_a_top_in": round(pic_top / EMU_PER_IN, 3),
                        "shape_b": f"Title-to-{col_shape.name} span",
                        "shape_b_top_in": round(span_top / EMU_PER_IN, 3),
                        "diff_in": round(abs(top_gap - bottom_gap) / EMU_PER_IN, 3),
                        "status": "FAIL",
                    })
                continue

            col_top = col_bounds[1]
            if abs(pic_top - col_top) > tol:
                rows.append({
                    "slide": i,
                    "shape_a": pic_shape.name,
                    "shape_a_top_in": round(pic_top / EMU_PER_IN, 3),
                    "shape_b": col_shape.name,
                    "shape_b_top_in": round(col_top / EMU_PER_IN, 3),
                    "diff_in": round(abs(pic_top - col_top) / EMU_PER_IN, 3),
                    "status": "FAIL",
                })
    return rows


def check_deck(pptx_path, overflow_tolerance_in, align_tolerance_in):
    prs = Presentation(pptx_path)
    overflow_rows = check_boundary_overflow(prs, overflow_tolerance_in)
    align_rows = check_cross_shape_alignment(prs, align_tolerance_in)
    return overflow_rows, align_rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("decks", nargs="+", help="One or more .pptx files to check")
    ap.add_argument("--overflow-tolerance-in", type=float, default=DEFAULT_OVERFLOW_TOLERANCE_IN,
                     help=f"Slop allowed past slide bounds before flagging, in inches (default {DEFAULT_OVERFLOW_TOLERANCE_IN})")
    ap.add_argument("--align-tolerance-in", type=float, default=DEFAULT_ALIGN_TOLERANCE_IN,
                     help=f"Max top-coordinate difference allowed for a side-by-side pair, in inches (default {DEFAULT_ALIGN_TOLERANCE_IN})")
    args = ap.parse_args()

    any_fail = False
    for deck_path in args.decks:
        print(f"\n{'=' * 100}")
        print(f"DECK: {deck_path}")
        print(f"{'=' * 100}")

        overflow_rows, align_rows = check_deck(deck_path, args.overflow_tolerance_in, args.align_tolerance_in)

        print("\n--- Boundary overflow (shape bounds vs slide_width/slide_height) ---")
        if not overflow_rows:
            print("  PASS — no shape extends past the slide bounds.")
        else:
            any_fail = True
            for row in overflow_rows:
                print(f"  FAIL slide {row['slide']}: {row['shape']!r} overflows — "
                      f"right:{row['over_right_in']:+.3f}in bottom:{row['over_bottom_in']:+.3f}in "
                      f"left:{row['over_left_in']:+.3f}in top:{row['over_top_in']:+.3f}in "
                      f"(positive = past the edge)")

        print("\n--- Cross-shape alignment (paired side-by-side shapes' top coordinates) ---")
        if not align_rows:
            print("  PASS — no misaligned side-by-side shape pairs found.")
        else:
            any_fail = True
            for row in align_rows:
                print(f"  FAIL slide {row['slide']}: {row['shape_a']!r} (top={row['shape_a_top_in']}in) vs "
                      f"{row['shape_b']!r} (top={row['shape_b_top_in']}in) — diff {row['diff_in']}in")

    print()
    if any_fail:
        print("RESULT: FAIL — see above for slides needing a fix.")
    else:
        print("RESULT: PASS — no boundary-overflow or cross-shape-alignment issues found.")
    sys.exit(1 if any_fail else 0)


if __name__ == "__main__":
    main()
