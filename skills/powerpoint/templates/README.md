# PowerPoint Templates

Branded `.pptx` files supplied by the user, kept here for reuse across future
decks instead of building from a blank theme every time.

## What belongs here
- `.pptx` files that define a look (theme, fonts, colors, layouts) the user
  wants applied to future presentations — usually sent because they liked a
  past deck's branding or have an existing company template.
- Not project content. A finished/one-off deck for a specific project still
  goes in `projects/<name>/`, never here.

## The index (`index.json`)
This folder is looked up via `index.json`, not by scanning filenames — it's
the single source of truth for what templates exist and how to match one to
a request. Never hardcode template names into skill instructions; always
read this file at runtime instead. Format:

```json
{
  "templates": [
    {
      "file": "<filename>.pptx",
      "name": "Short display name",
      "tags": ["style-or-topic-tag", "another-tag"],
      "description": "One sentence: what it looks like / what it's for."
    }
  ]
}
```

- `file` — the `.pptx` filename in this folder (relative, no path).
- `name` — a short human-readable label.
- `tags` — free-form lowercase keywords for matching (brand name, industry,
  visual style — e.g. `"corporate"`, `"minimal"`, `"acme"`). Add whatever
  tags make the template findable; there's no fixed vocabulary.
- `description` — a sentence a skill (or a human) can use to judge fit.

Starts empty (`"templates": []`). Add one entry per template file as they're
uploaded — see "Adding a new template" below.

## Naming convention for template files
`<short-topic-or-brand>.pptx` — lowercase, hyphenated. If the user names the
template when sending it, use that name (slugified); otherwise derive one
from the deck's title/branding. The filename itself is just an identifier —
matching is driven by the `index.json` metadata, not the filename.

## Lookup convention
Before building a new deck from scratch, read `index.json` and match its
entries against the request by topic/style using the `tags`/`description`
fields — don't assume a fixed list of templates, and don't hardcode any
template name into skill logic. If there's a plausible match, open that
template's file as the base `Presentation(...)` per
`skills/powerpoint/SKILL.md` → "Branded decks" so the new deck inherits its
theme. If nothing matches (including when the index is empty), fall back to
a blank presentation as before — don't force a mismatched template onto
unrelated content.

Templates in this folder are built **example-slide style**: each slide in
the `.pptx` is already a fully-styled instance of one logical layout (not a
python-pptx `slide_layouts` placeholder layout — python-pptx can't create
those through its high-level API), so reusing a layout means duplicating the
matching example slide and overwriting its text/placeholders, never adding a
slide from `slide_layouts[n]`. See `skills/powerpoint/SKILL.md` → "Branded
decks" for the concrete slide-number → layout table for the templates
currently here (both `clean-consulting.pptx` and `clean-photo-album.pptx`
ship the same 9 logical layouts — title, section divider, one-column,
two-column, big-stat, photo+caption, photo grid, quote, closing — in the
same slide order 1–9; `clean-consulting.pptx` additionally has native
chart/table layouts on slides 10–16). Keep new templates added to this
folder on that same 9-layout order where practical, so the position-based
lookup in the SKILL.md table keeps working across templates without
per-template special-casing.

## Adding a new template
**Trigger: only when the user explicitly asks to use/save a presentation as
a template** — e.g. "use this as a template," "save this as a template,"
"add this to the templates." A user sending a presentation file with no such
instruction is just sending a file (deck content, a reference, a one-off
project asset) — do not auto-ingest it into this folder or `index.json`
without that explicit ask. If it's ambiguous whether they want it saved as a
template, ask before adding it here.

Once that explicit request is confirmed, follow this procedure — it's the
same one used to add `clean-consulting.pptx` / `clean-photo-album.pptx` to
this folder (also prompted explicitly by the user), generalized:

1. **Receive and save the file.** Download the attachment (e.g.
   `mcp__plugin_telegram_telegram__download_attachment` for a Telegram file)
   to a scratch location — not this folder yet. If it's an archive (`.zip`),
   extract it and inspect the contents; it may contain more than one usable
   template (as the clean-consulting/clean-photo-album zip did) — treat each
   presentation file inside as a separate candidate and repeat this
   procedure for each one.
2. **Convert to `.pptx` if it isn't already one.** This folder only stores
   `.pptx` (see "What belongs here" above). If the user sent a Keynote
   (`.key`), OpenDocument (`.odp`), a Google Slides export, or any other
   format, convert it first via LibreOffice — see `skills/libreoffice/SKILL.md`
   for the conversion command (`soffice --headless --convert-to pptx`, same
   tool/pattern as the thumbnail QA step below, just a different
   `--convert-to` target). Never guess at a filename extension change; always
   run the actual conversion and verify the result opens with `python-pptx`
   (`Presentation(path)` should not raise).
3. **Render thumbnails and visually inspect it before naming/tagging
   anything.** Reuse the thumbnail QA step from `skills/powerpoint/SKILL.md`
   → "QA before delivering" (split into single-slide copies, then
   `soffice --convert-to png` each one) to render every slide, then actually
   read the images. Don't infer the template's name, style, or tags from the
   filename alone — the visual pass is what decides them (this is how
   `clean-photo-album.pptx` was confirmed to be an editorial/travel-journal
   style rather than assumed from its filename).
4. **Strip content, keep only style.** A template stores the *look*
   (theme/fonts/colors, master-slide layouts, placeholder structure) for
   reuse across many future decks — not the specific text/data/photos from
   whatever deck the user happened to send. Before saving the file into this
   folder:
   - **Text:** replace real body copy, headlines, numbers, and any
     deck-specific narrative with generic placeholder text (e.g. "Presentation
     Title," "Section title goes here," lorem-ipsum-style filler, or an
     explicit "replace with your own" instruction) — the same way
     `clean-consulting.pptx`'s example slides already read (see its README
     for the pattern: every slide is placeholder copy, sample chart data is
     labeled "replace with your data"). Keep the placeholder *shapes* and
     their formatting (font, size, color, position) exactly as they are —
     only the text content changes, so the layout stays intact and still
     demonstrates the styling.
   - **Images:** remove images that are topical content for that specific
     deck (a stock/personal photo illustrating that deck's subject matter —
     e.g. a "Malibu sunset" travel photo) and replace with a neutral
     placeholder block (as `clean-consulting.pptx`'s "YOUR IMAGE" rectangles
     already do) — never carry someone's one-off content photos into a
     reusable template. Keep genuine brand-identity assets that are meant to
     persist across every future use of the template — most commonly a
     company logo placed consistently in the same spot on every slide (a
     watermark, footer mark, or corner logo). Use judgment on which is which:
     an image that appears once, illustrating that one deck's topic, is
     content — strip it; an image/mark that recurs identically across slides
     in a fixed position, independent of the deck's subject, is brand
     identity — keep it (or keep it as a labeled placeholder like this
     template folder's own `LOGO` boxes if no real logo was supplied).
   - **Leave alone:** slide master layouts, theme colors/fonts, and the
     placeholder/shape structure itself — none of that is "content," it's
     the style being preserved.
   - This step is why finished example decks (real project content) belong
     in `projects/<name>/`, never here — see "What belongs here" above.
5. **Determine a name and tags.** If the user specified a name and/or
   category when sending the file (e.g. "call it X", "tag it Y") — as
   happened for `clean-consulting.pptx` ("Clean Consulting" /
   "Clean Consulting and Corporate") — use exactly what they said. Otherwise
   infer a short display name and descriptive lowercase tags from what step 3
   actually showed (palette, fonts, layout style, apparent use-case) —
   don't guess blindly. If a zip contains multiple distinct templates, apply
   any user-specified name only to the one it actually matches (by visual
   inspection) and infer sensible names/tags for the rest.
6. **Place the file.** Save the final, content-stripped `.pptx` into this
   folder using the naming convention above. This is the single shared
   template pool — there is no separate Google Slides templates folder
   (Slides decks reuse this same folder via the build-as-PowerPoint-first
   workflow, see `docs/google-slides-api.md`).
7. **Update `index.json`.** Add one entry (`file`/`name`/`tags`/`description`)
   per template following the schema above. Do this instead of editing any
   `SKILL.md` prose — the index is the only place template-specific
   information should live.
8. **Confirm with the user.** Briefly reply with what was added — the name(s)
   and tag(s)/category assigned to each template, and a one-line note that
   deck-specific content was stripped to placeholders — so they can correct
   it if the inferred naming/tagging (or what counted as "content" vs.
   "brand asset") missed the mark. No need for a long report; one short
   confirmation per upload is enough.

## Optional companion files (design tokens)

A template's *style* can optionally be documented outside the `.pptx` too —
e.g. a `tokens.json` capturing the palette/fonts/type-scale as structured
data, alongside a short design-system note. This is genuinely useful (a
skill or a human can read the palette/fonts without opening the file) and
`clean-consulting.pptx` / `clean-photo-album.pptx` were themselves generated
from exactly this kind of tokens file in the source material the user sent —
but it is **not required**. `index.json`'s `description` field is the
source of truth for what a skill needs at lookup time; a companion tokens
file, if added, is supplementary documentation only, named
`<same-basename>.tokens.json` alongside the `.pptx`, and must — like the
`.pptx` itself — describe style only (colors, fonts, spacing, type scale),
never deck-specific content.

## Current templates
- `clean-consulting.pptx` — minimalist corporate/consulting deck (teal/blue accents).
- `clean-photo-album.pptx` — editorial photo-album/travel-journal deck (yellow/magenta accents).

See `index.json` for full tags/descriptions. Add more the same way as they arrive.
