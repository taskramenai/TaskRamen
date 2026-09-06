# Corporate/Business Deck Styling Guide

Styling rules specific to **corporate/business-style decks** (quarterly
reviews, market/company analyses, consulting-style presentations, etc.) —
as opposed to editorial/narrative decks (e.g. photo journals, travel
albums) where these conventions don't apply. Both the PowerPoint skill
(`skills/powerpoint/SKILL.md`) and the Google Slides reference
(`docs/google-slides-api.md`) point here for this content; generic
slide-making advice (thumbnail QA, underfilled/overflow checks, branded
template lookup) stays in those files since it applies to all deck styles,
not just corporate ones.

## Visual balance (the principle behind the geometry rules)

Every slide's visual weight — text density, image size/placement,
whitespace, color — should read as **intentionally composed, not
lopsided**. A slide can be technically correct (no typos, accurate data,
grammatical bullets) and still look wrong because the weight on one side
or in one region visibly outweighs the rest with no deliberate reason.
"Balance" is the umbrella design principle; it isn't itself a new rule to
check separately — it's the underlying idea that several of this
document's concrete, checkable geometry rules each enforce a specific,
nameable symptom of:

- **Underfill check** — a top-anchored text box with dead space below its
  content is imbalanced *vertical* weight: the box implies content should
  fill it, and an unfilled remainder reads as an accident, not a design
  choice.
- **Cross-shape alignment** (including its half-width-title refinement
  below) — a picture and its paired text column with mismatched top edges
  (or a picture that doesn't span the full column it's paired against, on
  a half-width-title slide) is imbalanced *composition*: the reader's eye
  expects a shared row-start/row-span, and a mismatch reads as sloppy
  rather than deliberate.
- **Boundary overflow** — content spilling past the slide's edges is
  balance broken outright: weight isn't just distributed poorly, part of
  it is literally missing from the visible canvas.

Treat any future new geometry/spacing rule added to this document the same
way: name what specific kind of imbalance it's catching, not just the
mechanical check itself — that's what keeps these rules legible as one
coherent design principle instead of an arbitrary checklist.

**One further balance guideline not yet covered by a specific geometric
check — image weight vs. paired text density:** on a slide pairing a
picture with a text column (the same pairing the cross-shape-alignment
rule governs), the picture's visual size should roughly match the density
of its paired text block. Concretely: don't pair a small image against a
long, dense bullet list (the image reads as an afterthought against all
that text weight), and don't pair a large, dominant photo against just one
or two short bullet lines (the text reads as an afterthought squeezed in
next to the real content). As a rough, checkable proxy: compare the
picture's area (`width * height`) against the paired text box's total
character count (or bullet count, as a cheaper stand-in) — if one side's
box is at or near the layout's maximum available size while the other
side's content only lightly fills its own box, that's a visual-weight
mismatch to fix by either adding/trimming content on the light side or
adjusting the image's fitted size, not something to leave as "the layout's
default proportions."

## Font-size hierarchy (title > subheading > body)

Header and subheading text must be **visibly larger** than body/content
text, and sizes must follow a clear, consistent hierarchy across the whole
deck — not just "look bigger," a checkable size relationship:

- **Title** (slide title / big heading): largest size on the slide, 36-44pt.
- **Subheading** (section labels, callout headers, chart titles, column
  labels): smaller than the title but larger than body text, roughly
  20-28pt.
- **Body/content text** (bullets, paragraphs, captions, table cells):
  smallest of the three tiers, 14-18pt.
- **Footer/citation text** (see below): smaller still than body text —
  it should never be equal to or larger than the body copy it's
  attached to.

Concretely: every slide's title placeholder must use a larger `fontSize`
than every subheading/label on that slide, and every subheading must use a
larger `fontSize` than the body text in the same content block. If a slide
has no distinct subheading tier, the two-tier check (title > body) still
applies. Treat any slide where a subheading is the same size as or smaller
than adjoining body text, or where body text is the same size as or larger
than the title, as a QA failure to fix before delivering — the same way
overflow or underfill is a QA failure (see the QA sections in
`skills/powerpoint/SKILL.md` and `docs/google-slides-api.md`).

## Bullets, not plain text lines

Use bullet points (not plain unbulleted lines) to separate distinct items
within a text block — this is the standard convention for corporate/
business decks and reads more clearly than flowing prose broken into
separate lines. Editorial/narrative-style templates (e.g. photo journals)
may reasonably use flowing prose instead — use judgment based on the
template's own style.

## Selectively bold key words/phrases within bullet content

Within a bullet point's body text, bold the specific word(s), number(s), or
phrase(s) that carry the bullet's actual insight, rather than leaving the
whole bullet as uniform plain (or uniform bold) text. This lets a reader
scan a dense bullet list and immediately pick out the load-bearing facts
without reading every word.

- **Selective, not exhaustive.** Bold the 1-2 most important terms/figures
  per bullet, not every number or every other word. Over-bolding defeats
  the purpose — if everything stands out, nothing does.
- **Good candidates:** the specific statistic, dollar figure, or percentage
  that is the bullet's point; a named company, person, or product being
  introduced; a sharp qualifier that changes the claim's meaning (e.g.
  "not yet," "only," "first").
- **What not to bold:** connective/filler words, or an entire clause. Keep
  the bolded span to the load-bearing noun phrase or number itself, not the
  sentence around it.

Example: "Revenue grew **18% QoQ**, driven by **3 new enterprise logos**" —
not "Revenue grew 18% QoQ, driven by 3 new enterprise logos" (nothing
stands out) and not the whole sentence bolded (same problem in reverse).
See `skills/powerpoint/SKILL.md` for the python-pptx mechanics of building
a bullet with mixed bold/plain runs.

## Source citations go in a footer

Source/citation text (e.g. "Source: World Bank national accounts data...")
goes in a consistent bottom-left footer position: a horizontal line
running left-aligned along the bottom of the slide, in a small font (well
below body-text size) — not floating as a separate stacked text box
competing for space in a content column (e.g. next to a chart). Keep this
position consistent across every slide in the deck that needs a source
citation. This also structurally avoids the "floating element leaves an
awkward gap" QA failure (see the QA sections in `skills/powerpoint/SKILL.md`
and `docs/google-slides-api.md`), since the citation is no longer competing
for vertical space with other content.

## One key message per slide

A slide should carry a single message or insight, not multiple distinct
points crammed together. Before delivering, check each slide against a
simple test: can its content be summarized as one sentence? If a slide is
visibly doing double duty — e.g. it makes one point in its top half and an
unrelated second point in its bottom half, or a chart slide also tries to
make an unrelated argument in its callout text — split it into two slides
rather than leaving both messages competing for the same space. Don't force
a split where the content is genuinely one message with supporting detail
(e.g. a single insight backed by several bullet points is still one
message) — this rule targets slides carrying two or more unrelated
takeaways, not slides with multiple supporting facts for one takeaway.

## Headers are the insight, not a label

A slide's header/title should state the actual key takeaway or finding for
that slide, not a bland generic descriptor. This is sometimes called
"assertion-evidence" style: the header is the assertion, and the slide body
is the evidence for it.

- **Bad (label):** "Economic Overview", "GDP", "Key Industries".
- **Good (assertion):** "GDP growth accelerated to 4.2% in 2024", "Manufacturing
  and financial services drive a fifth of GDP each."

Concretely: read each header on its own, without the slide body. If it
could apply to any slide on the same general subject (i.e. it's a category
name rather than a specific claim), rewrite it to state the specific
finding, figure, or conclusion that the slide's own content actually
supports. Never invent a number or claim to make a header punchier — the
assertion must be grounded in data already present on that slide.

## Avoid word walls

Separate distinct points into their own bullets rather than combining
multiple ideas into one dense bullet or paragraph. A single bullet that
chains two or more separate facts together with commas, semicolons, or
"and" (e.g. "Strong GDP growth, low unemployment, and a stable currency
support continued investment") should be split into one bullet per idea.
The same check applies to prose paragraphs on narrative slides — a
paragraph that reads as several distinct points strung together should be
broken up so each idea is easy to scan on its own, not just easy to read
end-to-end.

## Coherent storyline/flow

Each slide should connect logically to the deck's overall narrative arc,
not read as a standalone, disconnected slide dropped in at that point.
Before delivering, read the sequence of slide headers top to bottom on
their own (per the "assertion, not label" rule above, each one should
already state its slide's key insight) — that sequence should read as a
coherent narrative, with a clear logical thread from one header to the
next, not a random-order list of unrelated facts. If reading the headers
in order doesn't tell a coherent story, reorder or rewrite so it does;
check for any hard dependencies between slides (e.g. a chart or image tied
to a specific slide position) before moving a slide, and don't reorder
purely for narrative polish if doing so is not a clear, low-risk change.

## Structure the storyline with the Minto Pyramid Principle (when appropriate)

For corporate/business decks, structure the overall slide sequence using
the Minto Pyramid Principle: lead with the answer/conclusion up front
(what the audience should walk away believing), then group the supporting
arguments that back it, then put the supporting data/detail beneath each
argument — top-down, not a slow build-up to a reveal at the end. Concretely:
an early slide (often the second or third, right after framing/context)
should state the deck's overall conclusion or recommendation as a specific
assertion (per the "headers are the insight" rule above, applied to the
deck's thesis, not just one slide), and the slides that follow should read
as the argument tree supporting that conclusion — each one a reason the
conclusion holds, backed by its own evidence — rather than a chronological
or exploratory walk that only arrives at the point at the end.

Use judgment on when this applies — don't force pyramid structure onto a
deck where it doesn't fit the content or purpose. It's a strong fit for
decks that exist to drive a decision or claim (investor pitches, business
cases, recommendations, status/results reviews making an argument about
performance). It's a poor fit for genuinely narrative or chronological
decks (e.g. "here's what happened this quarter, in order," a retrospective
walkthrough, a travel/photo album, a step-by-step tutorial) where the
sequence itself is the point and a lead-with-the-answer structure would
actively work against the content. This rule composes with "Coherent
storyline/flow" above: pyramid structure is one way (often the strongest
default for business decks) to make the header sequence read as a coherent
narrative, not a separate, competing requirement.

## Use real images, not generic stock or icons-only

When a slide profiles a specific company, product, or named person, use an
appropriate **real** image for it — an actual product photo/screenshot for
the company or product being discussed, the company's actual logo, or a
real photo of a named key person (e.g. a CEO or leadership team member) —
rather than defaulting to generic stock photography, icons-only treatment,
or a text-only slide. These images do **not** need to be copyright-free:
this is for personal-use analysis/pitch decks, not republishing or
commercial redistribution, so real product shots, company logos, press
photos, and executive headshots are fine to use, the same way any analyst
or journalist would reference them in a working document.

- **Bad:** a generic handshake stock photo on a partnership slide, a plain
  icon standing in for a product that has real screenshots available, a
  leadership slide with no photos of the actual people named.
- **Good:** an actual screenshot of the product being profiled, the
  company's own logo pulled from its press kit, a real headshot of the
  named executive from the company's newsroom or a reputable press source.

Image source citations follow the same footer convention as data source
citations above (bottom-left, small font, non-overlapping) — e.g. "Photo:
Company X press kit" or "Logo: company.com" — this is the same footer
mechanism, not a separate citation style.

If no genuinely relevant real image can be found for a given slide (e.g. a
private or obscure company with no available press assets), fall back to
the deck's existing non-image treatments — icons, charts, stat callouts —
rather than substituting an unrelated generic stock photo. Real-and-relevant
beats generic-but-present; generic-but-present beats fabricated-or-irrelevant.
See `skills/powerpoint/SKILL.md` → "Sourcing real images" for how to find
and embed these in this environment.

### Real-image cadence

Aim for roughly 1-in-3 to 2-in-3 slides in the deck to carry a relevant real
image (per the definition above — product photo/screenshot, company logo,
or named-person photo), not just "somewhere in the deck." Treat this as a
target ratio to aim for during sourcing, not a hard requirement that
overrides the fallback above: if a genuinely relevant image can't be found
for enough slides to hit that ratio, skip-rather-than-force still wins —
never fabricate relevance (e.g. an unrelated stock photo, or a real image
stretched to "count" for a slide it doesn't actually illustrate) just to
hit the number.

## Header length limit — the title box height and its divider are FIXED, never resized

A slide's title must fit within *whatever title-box height and divider
position the template itself was originally authored with* — read from
the actual template file, not a number hardcoded into any script or doc.
Both stay exactly where the template puts them, on every slide, always:
don't grow the title box and don't move the divider to force a fit. This
was a real, hard-won correction — earlier guidance treated 2 lines as an
allowed ceiling and let the layout grow to fit; in practice that made
every slide's divider sit at a different Y position depending on that
slide's own title length, which reads as inconsistent even when no single
slide technically overlaps. A template's decorative elements are supposed
to be identical across every slide; consistency of position beats
accommodating a longer title. This applies to WHATEVER template a deck
uses — the exact height/divider-position numbers below are one template's
measured example, not a universal constant to copy into other decks.

The two levers, in order:
1. **Shorten the wording.** The primary fix. When rewriting a header to
   satisfy the "assertion, not label" rule above, check the result against
   the template's real fixed budget as part of the same edit — a
   specific, data-grounded assertion still needs to be a tight, short
   claim, not a long sentence.
2. **A modest title font-size reduction, only if wording alone can't close
   the gap** — floor of **28pt**, and never so much that it breaks the
   font-size hierarchy (title text must stay clearly larger than
   section/column subheaders, which must stay clearly larger than body
   bullet text; if 28pt would put the title anywhere near subheader size
   on a given deck's type scale, that's over the line — shorten the
   wording more instead).

Concretely, on this deck's template (`clean-consulting.pptx`), the title
box is authored at a fixed 0.625in height with the divider at a fixed
1.34in from slide-top — at the standard 36pt title size this leaves room
for essentially **one line**, not two; a different template will have its
own numbers. Use `skills/powerpoint/check_title_divider_clearance.py`'s
`check_deck()` (or `fix_deck()`, which is detect-only now — see its
docstring, and note it always reads the divider's actual position from
the file, never a hardcoded value) to verify against the deck's real
rendered text, not a guessed character count; it reports exactly how far
over budget each offending title runs.

## When the template already has a title placeholder, use it — don't add a new textbox

When building a slide from a template/layout that already ships a title
**placeholder** shape (a `p:sp` with `<p:ph type="title"/>` or
`type="ctrTitle"`, reachable in python-pptx via `slide.shapes.title` or by
scanning `slide.placeholders`/`slide.shapes` for
`shape.is_placeholder and shape.placeholder_format.type in
(PP_PLACEHOLDER.TITLE, PP_PLACEHOLDER.CENTER_TITLE)` — the same check
`skills/powerpoint/check_title_divider_clearance.py`'s `find_title_shape()`
already does to locate a slide's title), populate that existing placeholder
rather than inserting a brand-new separate textbox on top of it.

- **Check first, every time:** before adding any title text to a slide,
  look for an existing title placeholder on that slide/layout. If one
  exists, set its text directly — `slide.shapes.title.text = "..."` or
  `slide.shapes.title.text_frame.text = "..."` (using the run-splitting
  pattern from `skills/powerpoint/SKILL.md` if the title needs mixed
  formatting) — rather than calling `add_textbox(...)` to create a new
  shape.
- **Only create a new textbox if no title placeholder exists** on that
  slide/layout (e.g. a from-scratch blank layout with no inherited
  placeholder structure at all).
- **Why this matters:** adding a duplicate textbox instead of reusing the
  placeholder produces two overlapping title-shaped text blocks in the same
  spot, formatting that doesn't match the template's intended title style
  (the placeholder inherits the template's title font/size/position from
  the slide master/layout; a manually-added textbox doesn't), and leftover
  duplicate-shape clutter in the file — the same class of problem as the
  duplicate-`cNvPr`-id issue in `skills/powerpoint/SKILL.md`'s "Known
  pitfalls," just triggered by a build script instead of an id-generation
  bug.
- This composes with, and comes before, the two title rules below: once
  the existing placeholder is the one being populated (not a new textbox),
  "Header length limit" governs how much text it can hold without resizing
  the template's fixed title-box height/divider, and "Title boxes should
  use the full available width" governs its width.

## Title boxes should use the full available width

A slide's title text box should use basically all the available
horizontal space up to the slide margins, not an artificially narrow box
— width is the one dimension that's fine to widen (it gives a longer
title more room on its single fixed-height line; it never touches the
divider). Different layouts within the same template can ship
inconsistent default title-box widths (e.g., in this template, some
layouts default to a title box as narrow as 7.29in on a 13.33in-wide
slide, while others already correctly use the safe max of 10.42in — right
up to the logo placeholder). When building a deck, don't just accept
whatever narrow default a given layout happens to ship with — explicitly
set every slide's title box width to match the widest safe value used
elsewhere in the same deck. This is the only layout dimension that's
adjustable — box height and divider position are not, per the rule
above.

## Underfill check: don't leave a top-anchored box with dead space below

A bullet/content text box that has significantly more vertical room than
its actual text needs is a QA failure, at the same severity tier as
overflow — not a lesser, cosmetic issue. This is a distinct failure mode
from the "large unused empty space" checks already covered in
`skills/powerpoint/SKILL.md` (which are about a slide's overall layout
area); this rule is about a *single box*, top-anchored, with a visible gap
of blank space below its last line of text before the box's own bottom
edge or the next element.

**Concretely, check this on every text box that carries a template's
inherited height** (a placeholder reused as-is, not resized to content):
compare where the last line of text actually ends against where the box
itself ends (and against the top of whatever comes next — a footer, the
slide bottom, another shape). A gap of roughly a third or more of the
box's own height, left empty below the text, is underfill.

**Root causes, in the order to check them:**
1. **The box is top-anchored (`anchor="t"`) with more height than the
   content needs** — most common when a layout's placeholder box height is
   authored generously (e.g. to accommodate a longer competing slide
   elsewhere in the deck) and a specific slide's content happens to be
   shorter. The box height itself isn't wrong; the anchor is.
2. **The content is genuinely thin** for the box it's been given — too few
   bullets, or bullets too short, for a box sized for more.

**Fixes, in order of preference — pick the one that actually fits, don't
default to the first:**
1. **Vertically center the text** (`anchor="ctr"` in OOXML terms —
   `pptx.enum.text.MSO_ANCHOR.MIDDLE` in python-pptx, or set the `a:bodyPr`
   element's `anchor` attribute directly) so the existing content
   distributes evenly within the box instead of pinning to the top with
   all the slack below. This is usually the right fix when the content is
   reasonable in amount but the box is simply taller than it needs to be —
   it requires no content changes and no risk of making the slide feel
   padded.
2. **Shrink the box to fit the content** plus reasonable padding, if
   centering alone still leaves the box looking oversized relative to the
   rest of the slide (e.g. a box that's 3x taller than its centered
   content needs).
3. **Add genuinely substantive content** — another real bullet, a
   supporting sub-point, a stat — only if the content is thin on its own
   merits (i.e., the slide's message really does have more to say and was
   just under-written), never as a filler-text patch purely to occupy
   space. If the content is already complete and correct as a message, use
   fix 1 or 2 instead of padding it out.

Never leave a box top-anchored with unaddressed dead space below on the
assumption that "it's not overflow, so it's fine" — per this rule, it's
its own QA failure class.

## Cross-shape alignment: paired shapes must share their `top` (and often `bottom`)

When a slide pairs two shapes that are meant to read as one visual row —
most commonly a text column next to a picture, but the same applies to any
side-by-side column layout (a two-column bullet comparison, a stat next to
its supporting chart, etc.) — their `top` coordinates must match, and
usually their `bottom` coordinates should land close together too, unless
there's a deliberate design reason for the offset (e.g. a caption
intentionally sitting lower than its image). This is a concrete, checkable
geometry rule, not a "make it look aligned by eye" judgment call:

- **Check:** read `shape.top` (EMU, via python-pptx) for both shapes in
  the pair. If they differ, that's a QA failure — the reader's eye expects
  a shared row-start, and even a fraction-of-an-inch mismatch reads as
  visibly "off" once the two shapes have very different content densities
  (e.g. a picture starting near the slide's top margin while its paired
  text column starts noticeably lower, below a title/kicker band).
- **Why this happens even without a build-script bug:** some templates'
  own layouts author paired placeholders (e.g. a picture placeholder and
  its paired body-text placeholder) at genuinely different `top` values —
  the picture placeholder spanning most of the slide's height while the
  text placeholder is authored lower, below where that slide's title sits.
  This is a template quirk to catch and correct in the build script, not
  something to assume is "how the template wants it" just because it came
  that way from `slide_layouts`.
- **Fix — figure out which shape has room to move, don't just slide
  either one blindly:**
  - If one shape (typically the text box) is constrained from above by
    another shape already on the slide (e.g. a title sitting directly
    above it), that shape's `top` is the fixed reference — move/resize the
    *other* shape (the picture) down to match it instead.
  - If the picture (or other shape) must shrink to be moved into
    alignment without running off the slide bottom, re-fit it into the
    smaller available box (recompute its aspect-fit size for the new,
    shorter height) — do not just reposition the original, unshrunk
    picture and let it hang off the bottom of the slide; that trades a
    top-alignment bug for an overflow bug. See "Boundary overflow" below
    for the margin to leave against a footer or the slide edge.
  - If neither shape is constrained by anything else, align both to
    whichever `top` value keeps the row highest without colliding with
    anything above it.
- This rule composes with, and is checked independently of, the underfill
  and boundary-overflow rules — a slide can pass all three or fail any
  subset of them; check each one explicitly rather than assuming a fix for
  one incidentally fixes another.
- **Mechanical check:** `skills/powerpoint/check_shape_geometry.py` checks
  this automatically (a picture vs. its paired text column's `top`) — see
  `skills/powerpoint/SKILL.md` → "QA before delivering" for how to run it.

### Refinement: half-width title + picture — span the full column, not just the bullets' top

The general rule above (picture's `top` matches the paired text column's
`top`) assumes the title sits *above* both the picture and the bullets,
spanning the slide's full content width — so aligning the picture to the
bullets' top is the same as aligning it to the whole text column. That
assumption breaks on a specific, common two-column layout: a slide where
the **title placeholder is itself narrow** — authored at roughly half (or
less) of the slide's width — because a picture occupies the other half,
stacked *beside* the title-and-bullets column rather than above it (e.g.
this repo's "Rubrik, innehåll och bild H/V" layouts, where the title box is
~34% of the slide width and the picture fills the other side).

On these slides, aligning the picture only to the bullets' top (the
general rule) leaves a visible gap above the picture, level with the title
— because the title itself is part of that column's vertical span, not a
separate band above it. The correct span for the picture is:

- **Top** = the TITLE placeholder's own `top` (not the bullet box's `top`).
- **Bottom** = the BULLET/content box's own `bottom` (`top + height`).

I.e. the picture should visually run the full title-to-bullets column
height, matching the *combined* vertical footprint of the title and its
bullets, not just top-aligning with where the bullets start.

- **How to tell if a slide qualifies:** compare the title placeholder's
  actual authored width against the slide width — read both from the file
  (`slide.shapes.title.width` vs. `prs.slide_width`), don't guess from the
  layout name. A title under roughly half the slide width, paired with a
  picture on the other side, qualifies. A slide whose title spans the
  slide's full content width (even if a picture also sits somewhere on
  that slide) does NOT qualify — that's the general cross-shape-alignment
  case above, not this refinement. A layout where the "title" placeholder
  is actually one large merged block holding both the headline AND the
  narrative bullets together (no separate bullet box to define a distinct
  bottom edge) also doesn't qualify — there's no second box to span down
  to, so the general rule (align to that one block's own top) already
  produces the right result.
- **Preserve aspect-fit — don't stretch the picture to fill the span
  edge-to-edge.** The picture is still fit into the (title-top,
  bullets-bottom) box the same way any other aspect-preserving fit works —
  centered within the fitted box. If the image's own aspect ratio doesn't
  exactly match the span's box ratio (e.g. a landscape 4:3 photo in a
  taller, narrower span), it will end up centered with a small, symmetric
  gap at both the top and bottom — that's correct, expected behavior, not
  a misalignment; the failure mode to actually catch is an *asymmetric*
  gap (e.g. still only touching the top, not reaching down toward the
  bottom at all).
- **Mechanical check:** `skills/powerpoint/check_shape_geometry.py`'s
  cross-shape-alignment check detects a half-width title automatically
  (title width under a configurable fraction of slide width) and switches
  to checking that the picture is vertically **centered** within the
  title-to-bullets span (top-gap and bottom-gap roughly equal), rather
  than requiring the picture to touch both edges exactly — see that
  script's docstring for the exact logic.

## Boundary overflow: not just titles — every content box must stay within the slide

The header-length-limit rule above (title box height and divider position
are fixed, never resized) covers *why* a title must not grow past its
box. This rule extends the same "must stay within bounds" QA check to
**every other content box on a slide** — body/bullet text boxes, picture
placeholders, footers, chart frames, anything with a `left`/`top`/`width`/
`height` — not just the title.

- **Check:** for every shape, `shape.left + shape.width` must be `<=
  prs.slide_width`, and `shape.top + shape.height` must be `<=
  prs.slide_height`. A shape that fails either check is spilling off the
  edge of the slide — a harder failure than underfill or misalignment,
  since content is being cut off or rendered outside the visible canvas
  entirely, not just badly spaced.
- **Don't stop at the placeholder's box bounds — check the actual fitted
  content too.** A picture placed via an aspect-fit helper, or a text box
  with `noAutofit` and enough text to wrap past its nominal height, can
  overflow even when the *placeholder* geometry looked fine; re-check
  final shape bounds after all content/fitting logic has run, not just the
  template's authored placeholder dimensions.
- **Leave a safety margin, don't cut it to zero.** A box whose bottom
  lands exactly flush with another element's top (e.g. a picture's bottom
  edge touching a footer's top edge with no gap) is fragile: a different
  renderer, a font substitution, or a slightly different text-wrap
  calculation can push it from "flush" to "overlapping." Keep a small but
  deliberate buffer (a tenth of an inch or more) between a content box's
  bottom and whatever sits below it (footer, slide edge), the same way the
  header-length-limit rule leaves headroom rather than fitting a title to
  the exact pixel.
- **Fix — per the same two-lever approach as titles, but for body content:**
  reword/shorten the content first if it's genuinely too much for a
  reasonably-sized box (per "Avoid word walls" above — long content is
  often better split across bullets or slides than crammed into an
  oversized box); resize the box/re-fit the image only when the box itself
  is the wrong size for content that's already appropriately concise.
  Never leave content rendering past the slide edge on the assumption that
  "PowerPoint will just clip it" — clipped, invisible content is a worse
  failure than a slightly-over-length bullet.
- **Mechanical check:** `skills/powerpoint/check_shape_geometry.py` checks
  every shape's bounds against `prs.slide_width`/`slide_height`
  automatically — see `skills/powerpoint/SKILL.md` → "QA before
  delivering" for how to run it. It only catches placeholder/final-shape
  geometry, not whether wrapped text renders past a box with `noAutofit`
  and no rendering step — pair it with a thumbnail render for that case.
