#!/usr/bin/env python3
# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)
"""
validate_pptx.py — lightweight OOXML/OPC validity gate for .pptx files.

Why this exists: a script duplicated a shape and computed the new shape's
`id` via `max(existing ids) + 1` while only scanning `<p:sp>` elements,
missing other shape kinds (`<p:graphicFrame>` for charts, `<p:pic>`,
`<p:cxnSp>`, `<p:grpSp>`) on the same slide — producing a duplicate `cNvPr`
id, which is invalid OOXML. Real PowerPoint shows a "needs repair" dialog on
open, but python-pptx and LibreOffice both silently tolerate it and open the
file fine — so a bare `soffice --convert-to pdf` smoke test does NOT catch
this bug class.

This is intentionally a GENERAL structural/OPC validity check, not a
single-bug regression test: we don't have real PowerPoint or the Open XML
SDK validator available, and vendoring full ECMA-376 XSD schemas would be
heavy/fragile for a "lightweight" gate. Instead it checks whole categories
of package-level corruption that are cheap to verify in pure Python:

  0. Zip integrity — `ZipFile.testzip()` catches a corrupt/truncated
     archive before any XML parsing is attempted.
  1. Every .xml/.rels part in the zip parses as well-formed XML.
  2. Content-type completeness — every part resolves to a declared content
     type via `[Content_Types].xml` (`<Default Extension=...>` or
     `<Override PartName=...>`); a part with no resolvable content type is
     invalid OPC.
  3. Relationship graph reachability — walk from the package root
     (`_rels/.rels`) through `ppt/_rels/presentation.xml.rels` and every
     part's own `_rels/*.rels`, recursively, and flag parts in the zip that
     are unreachable from the root as WARNINGs (orphaned-but-well-formed
     template cruft — not strictly illegal OPC, but worth a human's
     attention; e.g. unused template slides left in the package).
     Important nuance: `presentation.xml.rels` commonly declares
     relationships (rIds) to every slide part physically present in the
     package, even ones `presentation.xml`'s own `<p:sldIdLst>` never
     references — so a naive "follow every relationship" walk treats those
     as reachable and misses them. To catch this, the walk starts from
     presentation.xml's *actually-used* r:id set (the `r:id` attributes on
     `<p:sldId>`/`<p:sldMasterId>`/`<p:sldLayoutId>` entries) rather than
     blindly following every relationship `presentation.xml.rels` lists —
     an rId present in the .rels file but never referenced by
     `sldIdLst`/`sldMasterIdLst`/`sldLayoutIdLst` is exactly the orphan
     case this check exists to surface.
  4. Duplicate-id checks, generalized beyond the original cNvPr bug:
     - no duplicate <p:cNvPr> id within any single slide, scanning ALL
       shape kinds (p:sp, p:graphicFrame, p:pic, p:cxnSp, p:grpSp)
     - no duplicate Id attribute within a single .rels file
     - no duplicate id within presentation.xml's sldIdLst / sldMasterIdLst
       / sldLayoutIdLst
  5. Relationship reference integrity — every r:id/r:embed/r:link used in a
     part resolves to an entry in that part's .rels file, and every
     relationship's Target resolves to a real part in the zip (Internal
     mode only; External targets like URLs are skipped).
  6. Chart-XML schema-typed numeric fields — every `ppt/charts/chart*.xml`
     part is scanned for `<c:axId val="...">` with a negative value. Per the
     OOXML ChartML schema, `c:axId` is `CT_UnsignedInt` — a negative value
     isn't a valid lexical unsignedInt at all, so this is a real schema
     violation (hard FAIL), not a style nit. This was found baked into
     python-pptx's own bundled bar/line-chart XML templates
     (`pptx/chart/xmlwriter.py` hardcodes negative axId literals) — nothing
     build_deck.py did wrong, but `add_chart()` inherits it from whichever
     chart type template python-pptx uses. LibreOffice and python-pptx both
     silently tolerate it (so it slips past a smoke test and a python-pptx
     reload); real PowerPoint's stricter parser rejects the file outright.
  7. Element-ordering within `a:pPr` (CT_TextParagraphProperties) — the
     OOXML DrawingML schema requires `a:pPr`'s children in a strict sequence
     (lnSpc, spcBef, spcAft, buClrTx, buClr, buSzTx, buSzPct, buSzPts,
     buFontTx, buFont, buNone, buAutoNum, buChar, buBlip, tabLst, defRPr,
     extLst — matching python-pptx's own internal
     CT_TextParagraphProperties._tag_seq in pptx/oxml/text.py). Every `a:pPr`
     in every slide is checked; children out of that relative order is a
     hard FAIL, not a warning — like axId, this is a genuine schema
     violation. Found in practice: a build script's `set_space_after()`
     helper did a blind `pPr.append(spcAft)` after another helper had
     already appended the bullet-group elements (`buClr`/`buFont`/`buChar`),
     producing `lnSpc, buClr, buFont, buChar, spcAft` instead of the
     required `lnSpc, spcAft, buClr, buFont, buChar`. Well-formed XML either
     way, so LibreOffice/python-pptx open it fine — but real PowerPoint
     enforces the sequence and refuses to open the file at all. Unknown
     child tags (not in the schema list above) are skipped/ignored rather
     than flagged, so this check doesn't false-positive on elements it
     doesn't recognize.
  7b. Chart axis-id cross-reference integrity — c:crossAx is also
     CT_UnsignedInt (negative = hard FAIL, same as c:axId), every crossAx
     must match an existing axId in the same chart part (dangling = hard
     FAIL), and axis ids >= 2**31 draw a WARNING (schema-valid but outside
     the range any Office product writes).
  7c. CT_Color content model — a:buClr / a:solidFill / a:highlight must
     contain a direct color-choice child (a:srgbClr etc.), never a nested
     fill element. <a:buClr><a:solidFill>...</a:solidFill></a:buClr> was
     the issue #502 root cause: present on every bulleted slide of two
     independently built decks, tolerated by LibreOffice/python-pptx,
     rejected by real PowerPoint with the "needs repair" dialog. Checked
     across slides, layouts, masters, notesSlides and chart parts.
  8. A LibreOffice headless convert-to-pdf smoke test — kept as the last,
     cheap layer that catches total corruption/crashes the structural
     checks might not (files LibreOffice fails to load at all). NOT
     sufficient on its own: LibreOffice is lenient and happily opens files
     with duplicate shape ids, orphaned parts, negative axId values, or
     out-of-order pPr children.

Usage:
    python3 validate_pptx.py <file.pptx>

Exit code 0 = clean (WARNINGs allowed), non-zero = hard FAIL found (printed
to stdout, with WARNINGs also listed separately).
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from xml.etree import ElementTree as ET

NS = {
    "p": "http://schemas.openxmlformats.org/presentationml/2006/main",
    "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
    "ct": "http://schemas.openxmlformats.org/package/2006/content-types",
    "rel": "http://schemas.openxmlformats.org/package/2006/relationships",
    "c": "http://schemas.openxmlformats.org/drawingml/2006/chart",
    "a": "http://schemas.openxmlformats.org/drawingml/2006/main",
}

CNVPR_TAG = "{%s}cNvPr" % NS["p"]
RID_ATTR_RE = re.compile(r"^\{%s\}(id|embed|link|pict|dm|lo|qs|cs)$" % NS["r"])
AXID_TAG = "{%s}axId" % NS["c"]
CROSSAX_TAG = "{%s}crossAx" % NS["c"]
PPR_TAG = "{%s}pPr" % NS["a"]

# CT_Color content model (EG_ColorChoice): these container elements must hold
# a DIRECT color-choice child — never a fill element like <a:solidFill>.
# Found in practice (issue #502 root cause): a bullet-color helper wrote
# <a:buClr><a:solidFill><a:srgbClr/></a:solidFill></a:buClr> — well-formed
# XML that LibreOffice/python-pptx silently accept, but a genuine schema
# violation that real PowerPoint rejects with the "needs repair" dialog.
# a:solidFill itself (CT_SolidColorFill) has the same direct-color content
# model, so it's included as a container here too.
COLOR_CHOICE = {"{%s}%s" % (NS["a"], t) for t in
                ("scrgbClr", "srgbClr", "hslClr", "sysClr", "schemeClr", "prstClr")}
COLOR_CONTAINER_TAGS = {"{%s}%s" % (NS["a"], t): t for t in
                        ("buClr", "solidFill", "highlight")}

# CT_TextParagraphProperties (a:pPr) required child sequence per the OOXML
# DrawingML schema — matches python-pptx's own internal
# CT_TextParagraphProperties._tag_seq (pptx/oxml/text.py). Children not in
# this list (unknown/future elements) are ignored by the ordering check
# rather than flagged.
PPR_TAG_SEQ = (
    "lnSpc", "spcBef", "spcAft",
    "buClrTx", "buClr",
    "buSzTx", "buSzPct", "buSzPts",
    "buFontTx", "buFont",
    "buNone", "buAutoNum", "buChar", "buBlip",
    "tabLst", "defRPr", "extLst",
)
PPR_ORDER_INDEX = {"{%s}%s" % (NS["a"], t): i for i, t in enumerate(PPR_TAG_SEQ)}

PACKAGE_ROOT_RELS = "_rels/.rels"


def _rels_path_for(part_name):
    d = os.path.dirname(part_name)
    b = os.path.basename(part_name)
    if d:
        return f"{d}/_rels/{b}.rels"
    return f"_rels/{b}.rels"


def _resolve_target(base_dir, target):
    if target.startswith("/"):
        return target.lstrip("/")
    combined = os.path.normpath(os.path.join(base_dir, target))
    return combined.replace(os.sep, "/")


def find_problems(pptx_path):
    fails = []
    warnings = []

    if not zipfile.is_zipfile(pptx_path):
        fails.append(f"Not a valid zip archive: {pptx_path}")
        return fails, warnings

    with zipfile.ZipFile(pptx_path) as z:
        # --- 0. Zip integrity ---
        bad_entry = z.testzip()
        if bad_entry is not None:
            fails.append(
                f"Zip integrity check failed: {bad_entry!r} is corrupt/unreadable "
                f"(truncated or damaged archive)."
            )
            # Further checks would likely cascade-fail on a broken zip; stop here.
            return fails, warnings

        names = set(z.namelist())

        # --- 1. Every XML/.rels part must be well-formed ---
        xml_parts = {}
        for name in names:
            if name.endswith(".xml") or name.endswith(".rels"):
                try:
                    data = z.read(name)
                    xml_parts[name] = ET.fromstring(data)
                except ET.ParseError as e:
                    fails.append(f"Malformed XML in {name}: {e}")
                except Exception as e:
                    fails.append(f"Could not read/parse {name}: {e}")

        # First, collect every (resolved target, relationship Type) pair
        # declared across all .rels files in the package — used both by the
        # content-type check below (a part with a specific relationship
        # Type needs a specific Override, not just a generic Default) and
        # informs the reachability walk later.
        all_rel_targets = {}  # resolved part name -> set of relationship Types pointing at it
        for name in sorted(names):
            if not name.endswith(".rels"):
                continue
            rels_root = xml_parts.get(name)
            if rels_root is None:
                continue
            base_dir = os.path.dirname(os.path.dirname(name))  # strip "_rels"
            for rel in rels_root:
                target = rel.get("Target")
                mode = rel.get("TargetMode", "Internal")
                rtype = rel.get("Type", "")
                if mode == "External" or not target:
                    continue
                resolved = _resolve_target(base_dir, target)
                all_rel_targets.setdefault(resolved, set()).add(rtype)

        # --- 2. Content-type completeness ---
        ct_defaults = {}
        ct_overrides = {}
        ct_root = xml_parts.get("[Content_Types].xml")
        if ct_root is None:
            fails.append("Missing or malformed [Content_Types].xml — required OPC part.")
        else:
            for el in ct_root:
                tag = el.tag.rsplit("}", 1)[-1]
                if tag == "Default":
                    ext = el.get("Extension", "").lower()
                    ct_defaults[ext] = el.get("ContentType")
                elif tag == "Override":
                    part_name = el.get("PartName", "").lstrip("/")
                    ct_overrides[part_name] = el.get("ContentType")

            GENERIC_CONTENT_TYPES = {"application/xml", "application/octet-stream", "text/xml"}

            for name in sorted(names):
                if name == "[Content_Types].xml":
                    continue
                if name in ct_overrides:
                    continue
                ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
                default_ct = ct_defaults.get(ext)
                if default_ct is None:
                    fails.append(
                        f"{name} has no resolvable content type in "
                        f"[Content_Types].xml (no matching <Default Extension=\"{ext}\"> "
                        f"or <Override PartName=\"/{name}\">) — invalid OPC package."
                    )
                    continue
                # A part pointed at by a specific relationship Type (e.g. a
                # slide, chart, slideLayout) needs its own Override with the
                # matching specific content type — falling back to a generic
                # Default (application/xml etc.) is not enough for a part
                # PowerPoint expects to identify by content type, even though
                # it technically "resolves" per the OPC Default mechanism.
                if default_ct in GENERIC_CONTENT_TYPES and name in all_rel_targets:
                    fails.append(
                        f"{name} is referenced by a specific relationship "
                        f"({', '.join(sorted(all_rel_targets[name]))}) but has "
                        f"no <Override PartName=\"/{name}\"> in "
                        f"[Content_Types].xml — it only resolves to the "
                        f"generic Default for .{ext} ({default_ct}), which is "
                        f"not the specific content type PowerPoint expects "
                        f"for this part."
                    )

        # --- 3. Relationship graph reachability from the package root ---
        # Walk the graph, but at ppt/presentation.xml only follow the r:id
        # values it *actually references* via sldIdLst/sldMasterIdLst/
        # sldLayoutIdLst — not every relationship presentation.xml.rels
        # happens to declare (a generator commonly leaves rIds to unused
        # template slides sitting in the .rels file even though no
        # <p:sldId> points at them; those must show up as unreachable, not
        # get swept in just because the .rels entry exists).
        reachable = set()
        visited_rels = set()

        # Relationship Types that are gated by an explicit r:id living inside
        # <p:sldIdLst>/<p:sldMasterIdLst>/<p:sldLayoutIdLst> in
        # presentation.xml — i.e. a part of this Type is only "used" if its
        # rId is actually referenced there. Every other relationship Type
        # presentation.xml.rels declares (presProps, viewProps, tableStyles,
        # printerSettings, theme, etc.) is implicit/positional — OOXML
        # doesn't route those through an r:id anywhere in presentation.xml's
        # body, so they must always be followed, not gated.
        SLDLST_GATED_TYPES = (
            "/relationships/slide",
            "/relationships/slideMaster",
            "/relationships/slideLayout",
        )

        def presentation_used_rids(root):
            used = set()
            for list_tag in ("sldIdLst", "sldMasterIdLst", "sldLayoutIdLst"):
                list_el = root.find(f"p:{list_tag}", NS)
                if list_el is None:
                    continue
                for child in list_el:
                    rid = child.get(f"{{{NS['r']}}}id")
                    if rid:
                        used.add(rid)
            return used

        def walk(base_dir, rels_name, part_name):
            if rels_name in visited_rels or rels_name not in names:
                return
            visited_rels.add(rels_name)
            rels_root = xml_parts.get(rels_name)
            if rels_root is None:
                return

            gated_used_rids = None
            if part_name == "ppt/presentation.xml":
                pres_root = xml_parts.get(part_name)
                if pres_root is not None:
                    gated_used_rids = presentation_used_rids(pres_root)

            for rel in rels_root:
                rid = rel.get("Id")
                target = rel.get("Target")
                mode = rel.get("TargetMode", "Internal")
                rtype = rel.get("Type", "")
                if mode == "External" or not target:
                    continue
                if (gated_used_rids is not None
                        and rtype.endswith(SLDLST_GATED_TYPES)
                        and rid not in gated_used_rids):
                    continue  # declared in .rels but never referenced by *IdLst
                resolved = _resolve_target(base_dir, target)
                if resolved not in names:
                    continue  # reported separately as a dangling target below
                reachable.add(resolved)
                part_dir = os.path.dirname(resolved)
                part_rels = _rels_path_for(resolved)
                walk(part_dir, part_rels, resolved)

        walk("", PACKAGE_ROOT_RELS, "")
        reachable.add(PACKAGE_ROOT_RELS)
        reachable.add("[Content_Types].xml")

        unreachable = sorted(
            n for n in names
            if n not in reachable
            and not n.endswith(".rels")  # .rels parts are graph edges, not content nodes
        )
        if unreachable:
            warnings.append(
                "The following parts exist in the archive but are not reachable "
                "by walking the relationship graph from the package root "
                "(_rels/.rels -> ppt/_rels/presentation.xml.rels -> ...): "
                + ", ".join(unreachable) + ". These are individually well-formed "
                "and not a hard OPC violation, but they are typically orphaned "
                "template content (e.g. unused template slides) left over from "
                "a build step — worth a human review to decide if it's expected "
                "cleanup debt or a real bug."
            )

        # --- 4a. Duplicate cNvPr id within a slide ---
        slide_names = sorted(
            n for n in names if re.match(r"^ppt/slides/slide\d+\.xml$", n)
        )
        for slide_name in slide_names:
            root = xml_parts.get(slide_name)
            if root is None:
                continue
            ids_seen = {}
            for el in root.iter(CNVPR_TAG):
                shape_id = el.get("id")
                shape_name = el.get("name", "<unnamed>")
                if shape_id is None:
                    continue
                if shape_id in ids_seen:
                    fails.append(
                        f"Duplicate cNvPr id={shape_id!r} in {slide_name}: "
                        f"shape {ids_seen[shape_id]!r} and shape "
                        f"{shape_name!r} both use id {shape_id}. This is "
                        f"invalid OOXML — PowerPoint will show a 'needs "
                        f"repair' dialog even though python-pptx/LibreOffice "
                        f"open it fine. Likely cause: new-id computation "
                        f"(e.g. max(existing ids)+1) only scanned <p:sp> "
                        f"and missed another shape kind on this slide."
                    )
                else:
                    ids_seen[shape_id] = shape_name

        # --- 4b. Duplicate Id within a single .rels file ---
        for name in sorted(names):
            if not name.endswith(".rels"):
                continue
            root = xml_parts.get(name)
            if root is None:
                continue
            ids_seen = {}
            for rel in root:
                rid = rel.get("Id")
                target = rel.get("Target", "<no target>")
                if rid is None:
                    continue
                if rid in ids_seen:
                    fails.append(
                        f"Duplicate relationship Id={rid!r} in {name}: "
                        f"targets {ids_seen[rid]!r} and {target!r} both use "
                        f"id {rid} — each rId must be unique within its "
                        f".rels file."
                    )
                else:
                    ids_seen[rid] = target

        # --- 4c. Duplicate id within presentation.xml's *IdLst elements ---
        pres_root = xml_parts.get("ppt/presentation.xml")
        if pres_root is not None:
            for list_tag in ("sldIdLst", "sldMasterIdLst", "sldLayoutIdLst"):
                list_el = pres_root.find(f"p:{list_tag}", NS)
                if list_el is None:
                    continue
                ids_seen = {}
                child_tag = list_tag[:-3]  # sldId / sldMasterId / sldLayoutId
                for i, child in enumerate(list_el):
                    cid = child.get("id")
                    rid = child.get(f"{{{NS['r']}}}id", "<no r:id>")
                    if cid is None:
                        continue
                    if cid in ids_seen:
                        fails.append(
                            f"Duplicate id={cid!r} in ppt/presentation.xml "
                            f"<p:{list_tag}>: entries {ids_seen[cid]!r} and "
                            f"{rid!r} both use id {cid}."
                        )
                    else:
                        ids_seen[cid] = rid

        # --- 5. Relationship reference integrity (per-part dangling refs) ---
        for part_name, root in xml_parts.items():
            if part_name.endswith(".rels"):
                continue
            if "/_rels/" in part_name:
                continue

            rels_name = _rels_path_for(part_name)
            rel_targets = {}
            if rels_name in names:
                rels_root = xml_parts.get(rels_name)
                if rels_root is not None:
                    for rel in rels_root:
                        rid = rel.get("Id")
                        target = rel.get("Target")
                        mode = rel.get("TargetMode", "Internal")
                        rel_targets[rid] = (target, mode)

            used_rids = set()
            for el in root.iter():
                for attr, val in el.attrib.items():
                    if RID_ATTR_RE.match(attr):
                        used_rids.add(val)
            for rid in used_rids:
                if rid not in rel_targets:
                    fails.append(
                        f"{part_name} references relationship id {rid!r} "
                        f"that is not defined in {rels_name} "
                        f"(dangling r:id reference)."
                    )

            base_dir = os.path.dirname(part_name)
            for rid, (target, mode) in rel_targets.items():
                if mode == "External":
                    continue
                if target is None:
                    continue
                resolved = _resolve_target(base_dir, target)
                if resolved not in names:
                    fails.append(
                        f"{rels_name} relationship {rid!r} targets "
                        f"{target!r} (resolved: {resolved!r}) which does "
                        f"not exist in the archive (dangling relationship "
                        f"target / missing embedded object)."
                    )

        # --- 6. Chart-XML schema-typed numeric fields (negative c:axId) ---
        chart_names = sorted(
            n for n in names if re.match(r"^ppt/charts/chart\d+\.xml$", n)
        )
        for chart_name in chart_names:
            root = xml_parts.get(chart_name)
            if root is None:
                continue
            axid_vals = set()
            axref_els = []  # (tag_localname, val_str, val_int)
            for el in root.iter():
                if el.tag not in (AXID_TAG, CROSSAX_TAG):
                    continue
                raw_val = el.get("val")
                if raw_val is None:
                    continue
                try:
                    val = int(raw_val)
                except ValueError:
                    continue
                local = "c:axId" if el.tag == AXID_TAG else "c:crossAx"
                axref_els.append((local, raw_val, val))
                if el.tag == AXID_TAG:
                    axid_vals.add(val)
            for local, raw_val, val in axref_els:
                if val < 0:
                    fails.append(
                        f"{chart_name} has <{local} val=\"{raw_val}\"> — "
                        f"both c:axId and c:crossAx are CT_UnsignedInt per "
                        f"the OOXML ChartML schema, so a negative value is "
                        f"not a valid unsignedInt at all. LibreOffice/"
                        f"python-pptx open it anyway, but real PowerPoint "
                        f"rejects the file. Known source: python-pptx's own "
                        f"bundled chart XML templates (pptx/chart/"
                        f"xmlwriter.py) hardcode negative axis-id literals "
                        f"for some chart types. Fix by remapping every "
                        f"negative axis id to a positive value < 2**31, "
                        f"consistently across EVERY element that carries it "
                        f"— c:axId AND c:crossAx together (issue #502: a fix "
                        f"that rewrote only c:axId left c:crossAx negative "
                        f"and dangling, still unopenable)."
                    )
                elif val >= 2**31:
                    warnings.append(
                        f"{chart_name} has <{local} val=\"{raw_val}\"> — "
                        f"schema-valid unsignedInt, but no Office product "
                        f"ever writes axis ids >= 2**31; a strict/int32-"
                        f"based parser may reject it. Prefer remapping into "
                        f"the positive signed-int32 range."
                    )
            for local, raw_val, val in axref_els:
                if local == "c:crossAx" and val >= 0 and val not in axid_vals:
                    fails.append(
                        f"{chart_name} has <c:crossAx val=\"{raw_val}\"> "
                        f"but no <c:axId val=\"{raw_val}\"> exists in the "
                        f"same chart part — dangling axis cross-reference "
                        f"(axId values present: {sorted(axid_vals)}). Every "
                        f"crossAx must point at another axis's axId."
                    )

        # --- 7. a:pPr child element ordering (CT_TextParagraphProperties) ---
        for slide_name in slide_names:
            root = xml_parts.get(slide_name)
            if root is None:
                continue
            for ppr in root.iter(PPR_TAG):
                seq = [
                    PPR_ORDER_INDEX[child.tag]
                    for child in ppr
                    if child.tag in PPR_ORDER_INDEX
                ]
                if seq != sorted(seq):
                    child_names = [
                        child.tag.split("}", 1)[-1]
                        for child in ppr
                        if child.tag in PPR_ORDER_INDEX
                    ]
                    fails.append(
                        f"{slide_name} has an <a:pPr> with children out of "
                        f"schema order: {child_names} (expected relative "
                        f"order per CT_TextParagraphProperties: "
                        f"{list(PPR_TAG_SEQ)}). Well-formed XML either way, "
                        f"so LibreOffice/python-pptx open it fine, but real "
                        f"PowerPoint enforces the sequence strictly and will "
                        f"refuse to open the file. Common cause: a helper "
                        f"that does pPr.append(new_el) or pPr.insert(0, "
                        f"new_el) without checking where existing siblings "
                        f"(e.g. bullet elements added by another helper) "
                        f"already sit — insert at the schema-correct "
                        f"position instead (insert before the first "
                        f"existing child whose tag comes later in the "
                        f"sequence)."
                    )

        # --- 8b. CT_Color content model (buClr / solidFill / highlight) ---
        # These containers must hold a DIRECT color-choice child (a:srgbClr,
        # a:schemeClr, ...). Found in practice (issue #502 root cause): a
        # helper wrote <a:buClr><a:solidFill><a:srgbClr/></a:solidFill>
        # </a:buClr> on every bulleted slide — well-formed XML that
        # LibreOffice/python-pptx accept, but real PowerPoint rejects the
        # whole file with the "needs repair" dialog. Checked across slides,
        # layouts, masters, notesSlides AND chart parts.
        color_check_parts = sorted(
            n for n in names if re.match(
                r"^ppt/(slides/slide\d+|slideLayouts/slideLayout\d+"
                r"|slideMasters/slideMaster\d+|notesSlides/notesSlide\d+"
                r"|charts/chart\d+)\.xml$", n)
        )
        for part_name in color_check_parts:
            root = xml_parts.get(part_name)
            if root is None:
                continue
            for el in root.iter():
                local = COLOR_CONTAINER_TAGS.get(el.tag)
                if local is None:
                    continue
                bad = [ch.tag.split("}", 1)[-1] for ch in el
                       if ch.tag not in COLOR_CHOICE]
                if bad:
                    fails.append(
                        f"{part_name} has <a:{local}> containing "
                        f"{bad} — a:{local} is a color container whose "
                        f"content model requires a direct color-choice "
                        f"child (a:srgbClr, a:schemeClr, a:scrgbClr, "
                        f"a:hslClr, a:sysClr, a:prstClr), nothing else. "
                        f"E.g. wrapping the color in <a:solidFill> inside "
                        f"<a:buClr> is a schema violation LibreOffice/"
                        f"python-pptx tolerate but real PowerPoint rejects "
                        f"with the 'needs repair' dialog (issue #502 root "
                        f"cause)."
                    )

    return fails, warnings


def run_libreoffice_smoke_test(pptx_path, scratch_dir):
    """Last layer: convert to PDF headless. Catches crashes/total
    corruption the structural checker might not (e.g. LibreOffice refuses
    to load the file at all). NOT sufficient on its own — LibreOffice is
    lenient and happily converts files with duplicate shape ids or orphaned
    parts."""
    soffice = shutil.which("soffice") or shutil.which("libreoffice")
    if not soffice:
        return ["soffice/libreoffice not found on PATH — skipped LibreOffice smoke test"]

    profile_dir = os.path.join(scratch_dir, "loprofile")
    tmp_dir = os.path.join(scratch_dir, "lotmp")
    out_dir = os.path.join(scratch_dir, "loout")
    os.makedirs(profile_dir, exist_ok=True)
    os.makedirs(tmp_dir, exist_ok=True)
    os.makedirs(out_dir, exist_ok=True)

    env = dict(os.environ)
    env["TMPDIR"] = tmp_dir

    cmd = [
        soffice, "--headless", "--norestore",
        f"-env:UserInstallation=file://{profile_dir}",
        "--convert-to", "pdf", "--outdir", out_dir,
        pptx_path,
    ]
    try:
        result = subprocess.run(
            cmd, env=env, capture_output=True, text=True, timeout=90
        )
    except subprocess.TimeoutExpired:
        return ["LibreOffice convert-to-pdf smoke test timed out after 90s"]

    problems = []
    base = os.path.splitext(os.path.basename(pptx_path))[0]
    out_pdf = os.path.join(out_dir, base + ".pdf")
    if result.returncode != 0 or not os.path.exists(out_pdf):
        problems.append(
            "LibreOffice headless convert-to-pdf failed "
            f"(exit {result.returncode}): "
            f"{(result.stderr or result.stdout).strip()[:500]}"
        )
    elif os.path.getsize(out_pdf) == 0:
        problems.append("LibreOffice produced an empty PDF (0 bytes) — likely a crash")

    return problems


def main():
    if len(sys.argv) != 2:
        print(f"Usage: python3 {sys.argv[0]} <file.pptx>")
        sys.exit(2)

    pptx_path = sys.argv[1]
    if not os.path.isfile(pptx_path):
        print(f"File not found: {pptx_path}")
        sys.exit(2)

    fails, warnings = find_problems(pptx_path)

    with tempfile.TemporaryDirectory(prefix="validate_pptx_") as scratch:
        fails.extend(run_libreoffice_smoke_test(pptx_path, scratch))

    if warnings:
        print(f"WARNINGS: {len(warnings)}\n")
        for i, w in enumerate(warnings, 1):
            print(f"W{i}. {w}")
        print()

    if fails:
        print(f"FAIL: {len(fails)} problem(s) found in {pptx_path}\n")
        for i, p in enumerate(fails, 1):
            print(f"{i}. {p}")
        sys.exit(1)

    print(f"OK: {pptx_path} passed structural checks and LibreOffice smoke test.")
    if warnings:
        print(f"({len(warnings)} warning(s) above — review but not blocking.)")
    sys.exit(0)


if __name__ == "__main__":
    main()
