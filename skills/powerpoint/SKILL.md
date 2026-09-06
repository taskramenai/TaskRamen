# PowerPoint Skill (.pptx)

Create, read, and edit Microsoft PowerPoint decks locally with **python-pptx**
(MIT-licensed, no browser, no cloud). Use this for any request mentioning a
"deck", "slides", "presentation", or a `.pptx` file.

## Setup
`python-pptx` is pre-installed in the container image — no install step needed.
```bash
# Only if running outside the container (e.g. a bare host):
#   pip install --quiet python-pptx
```
To export a deck to PDF, LibreOffice is pre-installed → see `skills/libreoffice/SKILL.md`.

## Where files go
Always write to the active project folder: `projects/<name>/`. Never the repo root
or a system folder. Create the folder first if needed.

## Reading / extracting text
```bash
python3 - <<'PY'
from pptx import Presentation
prs = Presentation("projects/<name>/deck.pptx")
for i, slide in enumerate(prs.slides, 1):
    print(f"--- Slide {i} ---")
    for shape in slide.shapes:
        if shape.has_text_frame:
            print(shape.text_frame.text)
PY
```

## Creating a deck
Use `skills/powerpoint/example.py` as a starting template (copy into the project
folder and adapt). Core pattern:
```python
from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.dml.color import RGBColor

prs = Presentation()                      # blank 4:3; use template path for branded decks
prs.slide_width  = Inches(13.333)         # 16:9
prs.slide_height = Inches(7.5)

# Title slide
slide = prs.slides.add_slide(prs.slide_layouts[0])
slide.shapes.title.text = "Quarterly Review"
slide.placeholders[1].text = "Acme Pte Ltd — Q2 2026"

# Content slide with a bullet list
slide = prs.slides.add_slide(prs.slide_layouts[1])
slide.shapes.title.text = "Highlights"
tf = slide.placeholders[1].text_frame
tf.text = "Revenue up 18% QoQ"
for line in ["3 new enterprise logos", "Churn down to 1.2%"]:
    p = tf.add_paragraph(); p.text = line; p.level = 0

prs.save("projects/<name>/deck.pptx")
```

### Partial bolding within a bullet (mixed-formatting runs)

`skills/powerpoint/corporate-deck-style.md` → "Selectively bold key words/phrases within
bullet content" requires bolding just the load-bearing word/figure inside a
bullet, not the whole line. The pattern above (`p.text = line`) — and this
codebase's other bullet helpers that assign one run's `.text` for a whole
bullet — can only apply one formatting state to the entire paragraph,
because setting `.text` on a paragraph creates a single run. Bolding a
substring requires splitting that paragraph into multiple runs via
`add_run()`, one run per formatting change, each with its own `.font.bold`:

```python
p = tf.add_paragraph()
p.level = 0

r1 = p.add_run(); r1.text = "Revenue grew "
r1.font.bold = False

r2 = p.add_run(); r2.text = "18% QoQ"       # the load-bearing figure
r2.font.bold = True

r3 = p.add_run(); r3.text = ", driven by "
r3.font.bold = False

r4 = p.add_run(); r4.text = "3 new enterprise logos"
r4.font.bold = True
```

Keep bolded spans to 1-2 short phrases per bullet (per the style guide) —
in practice this means 3-5 runs per bullet: plain, bold, plain, bold, plain,
not a run per word. When a bullet-building helper takes a plain string
today, the build script needs a small extension (e.g. accept a list of
`(text, bold)` tuples, or split on `**marked**` spans) rather than passing
a whole pre-formatted string into a single `.text =` assignment.

## Editing an existing deck
Open it, mutate shapes in place, save (optionally to a new filename to preserve the
original). To replace text while keeping formatting, set `run.text` on the first run
rather than rewriting the whole text frame.

## Branded decks
If the user supplies a template `.pptx` (or one was matched via "Template
lookup" below), open THAT file as the `Presentation(...)` and build the new
deck from its **example slides**, not its `slide_layouts` — these templates
use the example-slide approach (python-pptx can't create new placeholder
layouts through its high-level API), so each slide in the template file is
already a fully-styled instance of one logical layout. To reuse a layout:
duplicate the matching example slide (copy its shapes/XML, or open a second
`Presentation(same_path)` and pull that slide's shapes across) and overwrite
its text/placeholder rectangles — never build a new slide from a blank
`slide_layouts[n]` when a template is in play, since that discards the
inherited styling.

**Concretely, this is what's actually in `skills/powerpoint/templates/`
today** (both templates ship the same 9 logical layouts in the same slide
order, so one lookup-by-position works for either):

| Slide # | Layout | What to overwrite |
|---|---|---|
| 1 | Title | eyebrow/label, title, subtitle (+ logo placeholder in Clean Consulting) |
| 2 | Section Divider | section number/kicker, section title |
| 3 | Content (one-column) | title, body |
| 4 | Two-Column | title, left label+body, right label+body |
| 5 | Big-Stat (3-up) | title, 3×(label, big number, caption) |
| 6 | Photo + Caption | title, 1 image placeholder, caption |
| 7 | Photo Grid (4-up) | title, 4 image placeholders (+ captions) |
| 8 | Quote | quote text, attribution |
| 9 | Closing | closing title, subtitle |

`clean-consulting.pptx` additionally has slides 10–16 as **native, editable**
analytics/chart layouts (column chart, line/trend chart, chart+insights,
two-chart comparison, KPI dashboard, data table, 2×2 matrix) — real
`add_chart`/table `GraphicFrame` objects, not images, so they stay editable
in PowerPoint/Slides after reuse. `clean-photo-album.pptx` stops at slide 9
(no chart layouts — it's a photo/travel theme, not built for data).

Image placeholders in both templates are plain colored rectangles (no
embedded photos in the `.pptx` — see "Turning a sent presentation into a
template" → content-stripping below for why), so "filling" an image
placeholder means calling `slide.shapes.add_picture(...)` positioned over
the placeholder rectangle, not editing an existing picture shape.

## Template lookup (before building from scratch)
Before starting a new deck, look up the appropriate template by reading
`skills/powerpoint/templates/index.json` and matching its entries against the
request by topic/style (tags/description) — rather than assuming a fixed
list of templates or hardcoding any template name. See that folder's README
for the index format and matching convention. If there's a plausible match,
open that entry's file as the base `Presentation(...)` per "Branded decks"
above so the deck inherits the existing theme. If nothing matches (including
when the index is empty), fall back to a blank presentation as before.

If the user hasn't supplied a template and the request would benefit from
consistent branding going forward, mention once that they can send an
existing PowerPoint or Google Slides presentation for TaskRamen to use as a
template — it gets saved into `skills/powerpoint/templates/` for reuse on
future decks (Google Slides decks are built from this same template pool —
see "Build new presentations as PowerPoint first, then upload" in
`docs/google-slides-api.md`). Don't repeat this prompt every time; a one-off
mention is enough.

## Turning a sent presentation into a template

**Trigger: only when the user explicitly asks for it** — "use this as a
template," "save this as a template," "add this to the templates," etc. A
presentation arriving as an attachment with no such instruction is just a
file (deck content to read/edit, a one-off reference, project material) —
don't auto-save it into the templates folder. If it's genuinely unclear
whether they want it kept as a reusable template, ask first.

Once the user has explicitly asked for it, the procedure is:
1. Receive/download the file and save it to a scratch location (not the
   templates folder yet); if it's an archive, extract it — it may contain
   more than one template, handle each separately.
2. If it isn't already `.pptx` (Keynote, ODP, a Slides export, etc.), convert
   it first via LibreOffice (`skills/libreoffice/SKILL.md`) — this folder
   only stores `.pptx`.
3. Render per-slide thumbnails (reuse "QA before delivering" → thumbnail
   render below) and actually look at them before naming or tagging
   anything — never infer style/category from the filename alone.
4. **Strip content, keep only style.** A template is style for reuse, not
   that deck's content: replace real body text/headlines/numbers with
   generic placeholder copy (keeping the placeholder shapes/formatting
   intact), and remove one-off content images (stock/personal photos
   illustrating that specific deck's topic) — but keep genuine recurring
   brand assets like a logo placed identically on every slide. Leave master
   layouts, theme colors/fonts, and placeholder structure untouched. Full
   guidance: `skills/powerpoint/templates/README.md` → "Adding a new
   template," step 4.
5. Name/tag it: use the user's own name/category if they gave one; otherwise
   infer from what the thumbnails actually show. For multiple templates in
   one upload, match any user-specified name only to the template it visually
   fits.
6. Save the content-stripped `.pptx` into `skills/powerpoint/templates/` (the
   single shared pool — Google Slides has no separate folder) and add an
   entry to that folder's `index.json` (file/name/tags/description).
7. Confirm back to the user what was added (name + tags, and that content was
   stripped to placeholders) so they can correct it if needed.

Full detail and rationale: `skills/powerpoint/templates/README.md` →
"Adding a new template."

## Design guidance (apply unless the user says otherwise)
- One dominant brand color (~60-70% of the palette) + 1-2 accents; be consistent across slides.
- Titles 36-44pt, body 14-18pt. Don't crowd slides — one idea per slide.
- Prefer a visual (chart, image, icon) over text-only slides. Sourcing images:
  if none provided, use copyright-free sources (Wikimedia Commons, Unsplash) and keep attribution.
- Title box width: explicitly set every slide's title box width to the deck's widest safe
  value rather than trusting the layout's default — layouts in `clean-consulting.pptx` are
  inconsistent (some default to a much narrower title box than others). See
  `skills/powerpoint/corporate-deck-style.md` → "Title boxes should use the full available width."
- Title box **height** and the divider below it: leave both exactly as the template authored
  them — never grow/move either to fit a long title. Write the title short enough to fit instead
  (a modest font-size reduction is a fallback, never below the deck's title-size range or close
  to subheader size). See `skills/powerpoint/corporate-deck-style.md` → "Header length limit."
- **When a slide's layout already has a title placeholder, reuse it — never add a second
  textbox on top of it.** Check `slide.shapes.title` (or scan `slide.placeholders`/
  `slide.shapes` for `shape.is_placeholder and shape.placeholder_format.type in
  (PP_PLACEHOLDER.TITLE, PP_PLACEHOLDER.CENTER_TITLE)`) before adding any title text; if a
  placeholder exists, set `.text`/`.text_frame` on it directly so it inherits the template's
  title formatting. Only call `add_textbox(...)` for a title when no placeholder exists at all.
  Skipping this check produces two overlapping title-shaped shapes with mismatched formatting.
  See `skills/powerpoint/corporate-deck-style.md` → "When the template already has a title placeholder, use
  it."
- Use `python-pptx` native charts (`add_chart`) for data rather than pasted screenshots.
- For corporate/business-style decks, see `skills/powerpoint/corporate-deck-style.md` for
  styling rules (font-size hierarchy, bullets vs prose, source-citation
  footer placement, real images vs stock/icons, etc.).

### Sourcing real images (for corporate decks profiling a company/product/person)

`skills/powerpoint/corporate-deck-style.md` → "Use real images, not generic stock or
icons-only" requires an actual product photo/screenshot, company logo, or
named-person photo where relevant, unlike the general copyright-free-only
guidance above. Note this needs a **live lookup, not an invented URL** —
never guess a Wikimedia filename or a press-kit path; find the real one
first.

Target cadence: aim for roughly 1-in-3 to 2-in-3 slides in the deck to carry
a relevant real image, not just one or two somewhere in the deck — see
`skills/powerpoint/corporate-deck-style.md` → "Real-image cadence." This is a sourcing
target, not a mandate to force an irrelevant image onto a slide just to hit
the ratio; step 4 below (skip rather than substitute) still wins when no
genuinely relevant image exists.

1. **Find the image, using live web tools:**
   - Company logos and product shots: the company's own newsroom/press-kit
     page or official product page (`WebSearch` for "`<company>` press kit"
     or "`<company>` newsroom", then open it with `agent-browser --cdp 9222`
     if it's JS-rendered — see `docs/websites.md` and
     `.agents/skills/agent-browser/SKILL.md`).
   - Named people: a Wikipedia/Wikimedia Commons photo where one exists
     (search, then open the Commons file page to confirm it's actually that
     person), or the company's own leadership/about page.
   - General fallback: an image search for the specific company/product/
     person, not a generic category term (search "`<company>` product
     screenshot", not "software product stock photo").
   - `WebFetch` only for a simple static page (e.g. reading a press page's
     HTML directly); use `agent-browser` for anything JS-rendered or that
     needs a snapshot to find the actual `<img>`/download link first.
2. **Download the binary**, then embed with python-pptx:
   ```bash
   curl -sSL -A "Mozilla/5.0 (compatible; TaskRamen/1.0)" \
     -o projects/<name>/assets/logo.png "<direct-image-url>"
   ```
   `curl -L` (with a `-A` user-agent — some sites, including Wikimedia,
   400/403 a bare default curl UA) reliably fetches a direct image URL in
   this environment — confirmed working, don't assume it's blocked without
   testing. For Wikimedia Commons specifically, use the stable direct-file
   redirect rather than guessing a thumbnail path:
   `https://commons.wikimedia.org/wiki/Special:FilePath/<File name.ext>`.
   If the source page has no plain image URL (e.g. it only renders via JS),
   use `agent-browser`'s screenshot/download commands instead (see "Downloads"
   in `.agents/skills/agent-browser/SKILL.md`) to capture it, then treat that
   file the same as a curl'd download. Then embed it:
   ```python
   slide.shapes.add_picture("projects/<name>/assets/logo.png",
                             left, top, width=width)  # height omitted -> keeps aspect ratio
   ```
   Pass only one of `width`/`height` (not both) so python-pptx scales the
   other dimension to preserve the source image's aspect ratio; size it to
   fit within the template's image-placeholder region (see "Branded decks"
   above for the Photo + Caption / Photo Grid layouts) rather than
   stretching it to exactly fill a differently-proportioned box.
3. **Cite it in the same footer as data citations** — `skills/powerpoint/corporate-deck-style.md`
   → "Source citations go in a footer" is the single citation mechanism for
   both data and images; don't invent a separate on-image caption style.
   E.g. "Photo: Acme Corp press kit" or "Logo: acme.com".
4. **If no genuinely relevant real image exists** (private/obscure company,
   no press assets, no photo of the named person), don't substitute an
   unrelated stock photo — fall back to the deck's existing non-image
   treatments (icons, charts, stat callouts) per the style guide.

## QA before delivering
1. Re-extract text (reader snippet above) and scan for typos / leftover placeholders.
1b. **Run the automated OOXML validity check on every built/edited deck before calling it
   done:** `python3 skills/powerpoint/validate_pptx.py projects/<name>/deck.pptx`. Exit
   code 0 = clean (WARNINGs may still print — review but non-blocking), non-zero = real
   problems found, printed with a specific explanation of each one.

   **Why this exists, and why a bare LibreOffice conversion is NOT enough:** LibreOffice and
   python-pptx are both far more lenient than real PowerPoint — several distinct OOXML schema
   violations have been found (the hard way, via a user's real-PowerPoint "needs repair" /
   can't-open error) that a `soffice --convert-to pdf` smoke test or a python-pptx reload
   completely miss. See "Known pitfalls" just below for the concrete bug classes this has
   caught so far. `validate_pptx.py` combines pure-Python OOXML/OPC structural checks
   (well-formed XML in every part, no duplicate `cNvPr`/relationship-`Id`/`sldIdLst`-`id`,
   every `r:id`/`r:embed`/`r:link` resolves, every part has a resolvable content type, zip
   integrity, no negative values in schema-typed-unsigned chart fields (`c:axId` AND
   `c:crossAx`, with axis-id cross-reference consistency), correct child element ordering in
   `a:pPr`, direct-color-child content in `a:buClr`/`a:solidFill`/`a:highlight` (no nested fill
   wrappers), and a relationship-graph reachability pass that flags
   orphaned-but-well-formed parts like unused template slides as warnings) with a LibreOffice
   headless convert-to-pdf smoke test as a last, cheap layer that catches total load failures
   the structural checks might miss. Run it as the automated catch-all going forward — don't
   rely on manually eyeballing shape-id logic, chart XML, or paragraph-property XML by hand.

### Known pitfalls (why `validate_pptx.py` exists)

These are concrete bug classes discovered in this deck-building skill so far — all well-formed
XML that LibreOffice and python-pptx silently open without complaint, but that real PowerPoint
rejects outright (a "needs repair" dialog or a flat "can't open file" error). `validate_pptx.py`
checks for all of them automatically; treat a clean run as the bar, not a manual read of the
generated XML.

- **Duplicate `cNvPr` shape ids.** Computing a new shape's `id` via `max(existing ids) + 1`
  while only scanning `<p:sp>` elements misses other shape kinds on the same slide
  (`<p:graphicFrame>` for charts/tables, `<p:pic>`, `<p:cxnSp>`, `<p:grpSp>`) — the new id can
  collide with one of those. Fix: scan every shape kind (e.g. iterate
  `slide.shapes._spTree.iter(qn('p:cNvPr'))`), not just `<p:sp>`, when generating new ids.
- **Negative chart axis ids — in `c:axId` AND `c:crossAx`.** Found baked into python-pptx's own
  bundled bar/line-chart XML templates (`pptx/chart/xmlwriter.py` hardcodes negative axis-id
  literals for some chart types) — not something a build script did wrong, but inherited from
  whichever chart-type template `add_chart()` uses. Per the OOXML ChartML schema, both `c:axId`
  and `c:crossAx` are `CT_UnsignedInt`, so a negative value is not a valid unsignedInt at all.
  Fix: right after `add_chart()`, remap every negative axis id to a positive value **across
  every element that carries it — `<c:axId>` and `<c:crossAx>` together**. Issue #502 lesson:
  an earlier fix rewrote only `c:axId`, leaving `c:crossAx` both negative (still schema-invalid)
  and dangling (pointing at an axis id that no longer existed) — the file still failed to open.
  Also keep the remapped value `< 2**31` (e.g. `abs(val)`, with collision checks): `val + 2**32`
  is schema-valid unsignedInt but lands in a range no Office product ever writes axis ids in,
  which a strict/int32-based parser may reject.
- **`a:pPr` children out of schema order.** `CT_TextParagraphProperties` (`a:pPr`) requires its
  children in a strict sequence (`lnSpc, spcBef, spcAft, buClrTx, buClr, buSzTx, buSzPct,
  buSzPts, buFontTx, buFont, buNone, buAutoNum, buChar, buBlip, tabLst, defRPr, extLst` — matches
  python-pptx's own internal `CT_TextParagraphProperties._tag_seq`). A helper that does a blind
  `pPr.append(new_el)` or `pPr.insert(0, new_el)` without accounting for siblings another helper
  already added (e.g. setting line spacing after bullets were already added, or vice versa) can
  silently produce out-of-order XML. Fix: insert new `pPr` children at the schema-correct
  position (before the first existing sibling whose tag comes later in the canonical sequence),
  not via a blind append/insert.
- **A fill element nested inside a color container (`<a:buClr><a:solidFill>…`).** This was the
  actual root cause of issue #502 — two independently built decks that passed every other check
  both failed to open in real PowerPoint ("needs repair" + "content that can't be verified"
  banner) because a shared bullet helper wrote
  `<a:buClr><a:solidFill><a:srgbClr …/></a:solidFill></a:buClr>` on every bulleted paragraph.
  `a:buClr` is `CT_Color`: its content model is a **direct** color-choice child (`a:srgbClr`,
  `a:schemeClr`, `a:scrgbClr`, `a:hslClr`, `a:sysClr`, `a:prstClr`) — never a fill wrapper.
  The same direct-color rule applies to `a:solidFill` itself and `a:highlight`. LibreOffice and
  python-pptx render the wrapped form without complaint (which is why thumbnail QA and reload
  checks missed it); real PowerPoint rejects the whole file. Symptom fingerprint: the title
  slide (typically bullet-free) partially renders behind the error dialog, because the parser
  dies on the first bulleted slide. Fix: append the color element directly to `buClr`.
- **A fixed-position decorative element (divider/rule) treated as movable instead of the title
  text being treated as adjustable.** Templates place a divider line at a fixed y-position sized
  for the template's own title-box height (e.g. a `Connector` shape sitting just below a 1-line
  title box). The first fix attempt here grew the title box and moved the divider down to match
  whenever a title wrapped to 2+ lines — that avoids the overlap, but it leaves the divider at a
  *different Y position on every slide* depending on that slide's own title length, which reads
  as inconsistent even when no slide technically overlaps (a real user call, after this got
  "fixed" three times and still didn't look right). **Corrected approach: the title box height and
  divider position are read from the template and never modified — see
  `skills/powerpoint/corporate-deck-style.md` → "Header length limit."** `check_title_divider_clearance.py`'s
  `fix_deck()` is detect-only now: it reports which slides overflow the template's own fixed
  budget (with the actual title text and how far over), and the fix is a shorter title — with a
  modest font-size reduction as a secondary lever, only if it doesn't threaten the title >
  subheader > body size hierarchy. Never grow the box, move the divider, or shift other shapes to
  accommodate a long title.
- **Orphaned template parts left in the zip.** Removing a slide from `<p:sldIdLst>` alone
  doesn't remove it from the package — python-pptx's `Package.save()` only omits parts
  unreachable via the *relationship graph* (`Package.iter_parts()` walks `iter_rels()`, not
  `sldIdLst`), so a slide (and anything only it references, e.g. its chart/embedded-workbook
  parts) stays in the output zip as dead weight unless its relationship is also dropped (e.g.
  `prs.part.drop_rel(rId)`). Not a hard corruption — `validate_pptx.py` flags this as a
  non-blocking WARNING rather than a FAIL — but worth cleaning up when noticed, since it bloats
  the file with debris from every rebuild.

**Architectural root cause worth revisiting (not yet fixed):** hand-copying a slide's shape
tree via `copy.deepcopy()` on raw XML elements (rather than going through a higher-level
duplication API) is the pattern behind the duplicate-shape-id bug above, and is a known general
risk area for OOXML tooling more broadly — manual XML cloning has no built-in awareness of
id-uniqueness, relationship rewriting, or schema-required element ordering, so every new
duplication site can reintroduce a variant of the same class of bug. This skill's own
`duplicate_slide()` pattern (deep-copying every shape element from a source slide into a new
one) is exactly this shape. Not being rewritten as part of this fix — the existing deep-copy
approach is stable and a rewrite risks introducing new bugs under time pressure — but flagged
here as a structural weak point to revisit if this bug class recurs elsewhere.

**`validate_pptx.py` is a pragmatic subset, not full schema validation.** Its checks (XML
well-formedness, duplicate-id detection, dangling-reference detection, and element ordering for
the specific complex types checked so far) are hand-rolled heuristics targeting the concrete bug
classes actually hit in this skill, not a general-purpose ECMA-376/ISO-29500 XSD validator. A
clean run is good evidence a deck avoids the known bug classes above, but it is not a 100%
guarantee of OOXML validity — real PowerPoint opening the file cleanly remains the actual ground
truth. Extend the script's checks as new bug classes are discovered, the same way the three
above were added.
2. **Always visually verify with a per-slide thumbnail render.** For a
   brand-new deck, or any major change to an existing one, don't consider the
   work done from the text/XML alone — render each slide to an image and
   actually look at it: check layout (overlap, overflow off the slide,
   alignment, spacing), readability (contrast, font size), and overall visual
   attractiveness. This mirrors the same requirement for Google Slides (see
   `docs/google-slides-api.md` → "Always visually verify with the thumbnail
   API") so both formats get the same level of scrutiny before delivery.

   **Also check for large unused empty space**, not just overflow/overlap —
   the opposite failure is just as visible, and it shows up in **two
   distinct forms**, so check for both:
   - **A single block leaving dead space around it:** a small text block or
     object floating in the top third (or any corner) of an otherwise-blank
     slide, with a big dead margin-aside gap below/beside it. A two-column
     text block that only reaches a third of the way down the slide reads
     as unfinished, not minimal.
   - **A gap BETWEEN multiple separate elements in the same region:** even
     when a region has more than one discrete text/content element (e.g. a
     callout box and a caption, or a heading and a citation), each
     individual element can look "filled" on its own while the *space
     between* them is still a large dead gap — one element pinned near the
     top of its area and another pinned near the bottom, with nothing in
     between. This is easy to miss if you only check "is this one block
     followed by empty space" — check the gap between every pair of
     elements in a shared region, not just whether each element individually
     has room around it.

   Content should be sized, spaced, or expanded to reasonably fill the
   slide's layout area (margins aside). **Exception:** don't force every
   slide to be dense — a mostly-empty layout can be a deliberate stylistic
   choice (a quote slide, a title slide, a big-stat slide where whitespace
   is the point) — use judgment on whether the emptiness is intentional
   design breathing room or just underfilled content, the same judgment call
   as the rest of this QA step.

   When it's the latter (underfilled, not deliberate), concrete ways to fix
   it — pick whichever fits the content, don't just leave it as-is:
   - Increase font size / line spacing so the existing text occupies more
     of the vertical space.
   - Add a supporting visual element in the empty area — an icon, a chart,
     an image, a stat callout — rather than leaving it blank.
   - Expand or redistribute the content itself: add supporting bullets/sub-points,
     split one sparse block into the template's two-column or grid layout,
     or pull in another idea that belongs on the same slide.
   - Resize and reposition the text block/placeholder to occupy the
     available area proportionally (e.g. vertically center or stretch it
     across the full content region) instead of leaving it anchored at the
     top with the rest of the slide dead.
   - **For a gap between multiple elements specifically:** redistribute them
     to use more even/proportional spacing across the shared region (rather
     than one pinned at the top and another at the bottom), add another
     genuinely useful piece of content between them (an additional stat, a
     secondary insight, a small supporting visual) if that reads better than
     just closing the gap, or reposition them closer together with sensible
     margins. Note `python-pptx` shapes using `auto_size=SHAPE_TO_FIT_TEXT`
     shrink-wrap to their content regardless of an explicit box height —
     resizing the box alone won't visually fill the space; either turn off
     autofit and vertically anchor the text, or add enough content that the
     shape naturally grows to fill it.

   **These checks are all specific, checkable instances of one broader
   principle — visual balance** (`skills/powerpoint/corporate-deck-style.md` → "Visual
   balance"): a slide's visual weight (text density, image size/placement,
   whitespace, color) should read as intentionally composed, not lopsided.
   Underfill is imbalanced vertical weight, cross-shape misalignment is
   imbalanced composition, boundary overflow is balance broken outright,
   and an image paired with a mismatched-density text block (too small
   next to a dense bullet list, or too large next to a couple of short
   lines) is an imbalance of visual weight between the two — see that doc
   section for the full framing and a proxy check for the image/text-density
   case. Keep this framing in mind for any new spacing/geometry issue found
   in future QA: name what kind of imbalance it is, not just the mechanical
   symptom.

   **Also check these three related, but distinct, box-level failure
   classes** — same severity tier as the slide-level empty-space check
   above, but scoped to individual shapes rather than the whole slide's
   layout area; full detail and fixes in `skills/powerpoint/corporate-deck-style.md`:
   - **Underfill check** (`skills/powerpoint/corporate-deck-style.md` → "Underfill
     check"): a single top-anchored box whose text ends well above the
     box's own bottom edge (roughly a third or more of the box left empty
     below the last line) — fix by vertically centering the text in the
     box, shrinking the box to content, or adding genuine content, in that
     order of preference. Stays a manual/visual check (no mechanical script
     for this one) — it needs real text measurement (where the wrapped
     text actually ends inside the box), which requires a rendering engine
     or font-metric layout code this repo doesn't have; a box's declared
     height/position alone can't tell you how much of it the text fills.
   - **Cross-shape alignment** (`skills/powerpoint/corporate-deck-style.md` →
     "Cross-shape alignment"): any two shapes meant to read as one visual
     row (most often a text column paired with a picture) must share the
     same `top` — check `shape.top` on both and fix whichever shape has
     room to move, re-fitting a picture into its new, smaller box rather
     than letting an unshrunk picture hang off the slide. **Refinement for
     half-width titles** (`skills/powerpoint/corporate-deck-style.md` → "Refinement:
     half-width title + picture"): when the title placeholder itself is
     narrow — under roughly half the slide width, because a picture
     occupies the other half beside the title+bullets column — the picture
     should span the FULL column height instead: top = the title's own
     `top`, bottom = the bullet box's own `bottom`, not just top-aligned
     with the bullets. Still aspect-fit (centered) into that span, so a
     small symmetric gap at both edges is expected when the image's ratio
     doesn't exactly match the span's box ratio — only an *asymmetric* gap
     is a real misalignment.
   - **Boundary overflow** (`skills/powerpoint/corporate-deck-style.md` → "Boundary
     overflow"): not just titles — every shape's `left + width` and
     `top + height` must stay within `prs.slide_width`/`slide_height`,
     with a small safety margin against whatever sits just below it (a
     footer, the slide edge), not a zero-margin flush fit.

   **Both the cross-shape-alignment and boundary-overflow checks are pure
   geometry (no text measurement needed) and have a mechanical check:**
   `python3 skills/powerpoint/check_shape_geometry.py projects/<name>/deck.pptx`
   — run it alongside `validate_pptx.py` before calling a deck done. It
   flags every shape that extends past the slide bounds, and every
   picture/text-column pair on a slide whose `top` values don't match
   (using a heuristic to find "paired side-by-side shapes" — see its own
   docstring for the exact rule and known false-positive cases, e.g. a
   title-slide logo that was never meant to align with the subtitle text;
   use judgment on any FAIL it prints, the same way
   `check_title_divider_clearance.py`'s SKIP rows need judgment about which
   shape is really "the title"). It also auto-detects the half-width-title
   case (title width under a configurable fraction of slide width) and
   switches its expected geometry accordingly — checking that the picture
   is centered within the title-to-bullets span rather than flagging the
   deliberate top/bottom offset from the bullet box alone as a failure.
   Exit 0 = no findings.

   Use LibreOffice (see `skills/libreoffice/SKILL.md`) to render one PNG per
   slide. **Note:** `soffice --convert-to png` on a multi-slide `.pptx` only
   exports the first slide, not one image per slide — so split the deck into
   single-slide copies first, then convert each:
   ```bash
   LO_WORK="${CLAUDE_HOME:-$HOME/taskramen}/.cache/libreoffice"
   mkdir -p "$LO_WORK/profile" "$LO_WORK/tmp" projects/<name>/thumbnails/

   python3 - <<'PY'
   from pptx import Presentation
   src = "projects/<name>/deck.pptx"
   n = len(Presentation(src).slides)
   for i in range(n):
       prs = Presentation(src)
       ids = list(prs.slides._sldIdLst)
       for j, sld in enumerate(ids):
           if j != i:
               prs.slides._sldIdLst.remove(sld)
       prs.save(f"projects/<name>/thumbnails/_slide{i+1}.pptx")
   PY

   for f in projects/<name>/thumbnails/_slide*.pptx; do
     TMPDIR="$LO_WORK/tmp" soffice --headless --norestore \
         -env:UserInstallation="file://$LO_WORK/profile" \
         --convert-to png --outdir projects/<name>/thumbnails/ "$f"
     rm "$f"
   done
   ```
   This produces one `_slideN.png` per slide in `projects/<name>/thumbnails/`.
   Read each image and fix any issue found, then re-render to confirm before
   calling the deck done. A plain PDF render (as before) is an acceptable
   quick substitute only for a minor, low-risk edit.
3. Fix and re-verify any slide you changed.

## Delivering to the user
Send the finished `.pptx` (and PDF preview if generated) via the file-send tool.
Send the file as-is — do not repackage or compress it first.
