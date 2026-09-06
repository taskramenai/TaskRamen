# Form Filling Patterns

Reference for common widget types. Use this before attempting to fill any form.

## React Controlled Inputs
`fill <ref> <value>` sets DOM value but React doesn't register it — form submits empty.

**Fix:** Use `fill` then verify:
```bash
npx agent-browser --cdp 9222 fill e42 "YourFirstName"
npx agent-browser --cdp 9222 eval "document.querySelector('input[name=firstName]').value"
```
If value doesn't stick, use Puppeteer page.type() instead — it fires real keystrokes:
```js
await page.type('input[name="firstName"]', 'YourFirstName', { delay: 50 });
```

## Material UI Date Pickers
DO NOT click the calendar icon and navigate month-by-month — takes 20+ calls.

**Fix:** Click the text input directly, then type the date:
```bash
npx agent-browser --cdp 9222 click <date-input-ref>
npx agent-browser --cdp 9222 eval "
  const inp = document.querySelector('input[placeholder*=\"date\"], input[placeholder*=\"Date\"], input[type=\"date\"]');
  if (inp) { inp.value = '2000-01-01'; inp.dispatchEvent(new Event('input', {bubbles:true})); inp.dispatchEvent(new Event('change', {bubbles:true})); }
"
```
Or with Puppeteer: `await page.type('input[type="date"]', '01012000')` (MMDDYYYY for US format) or `'01012000'` (DDMMYYYY for EU).

For MUI date pickers that show a MM/DD/YYYY placeholder, type the digits with no
slashes — e.g. `01012000` for 1 January 2000. Read the real value from
personalinfo.md; never hardcode a date here.

## React Select / Custom Dropdowns
Standard `<select>` elements work with agent-browser select command. Custom React dropdowns need:
1. Click the dropdown control
2. Wait 500ms for options to render
3. Type to filter, then click the first matching option

```bash
npx agent-browser --cdp 9222 click <dropdown-ref> && npx agent-browser --cdp 9222 wait 500
npx agent-browser --cdp 9222 fill <search-input-ref> "<value>"  # use user's city/country from personalinfo.md
npx agent-browser --cdp 9222 wait 500
npx agent-browser --cdp 9222 click <first-option-ref>
```

## City/Location Autocomplete
Common on travel, delivery and billing-address forms. These autocomplete fields
load suggestions asynchronously, so the value you type is not the value that gets
submitted until you pick from the list.
1. Fill the input
2. Wait 1000ms for suggestions
3. Use snapshot -i to find the suggestion list
4. Click the correct suggestion

```bash
npx agent-browser --cdp 9222 fill <city-input-ref> "<city>" && npx agent-browser --cdp 9222 wait 1000  # use user's city from personalinfo.md
npx agent-browser --cdp 9222 snapshot -i
# Click the suggestion ref from snapshot
npx agent-browser --cdp 9222 click <suggestion-ref>
```

## Phone Number Fields with Country Code
Always include country code. See personalinfo.md for the user's phone number and country code, then fill accordingly.
Check if there's a separate country code dropdown — select the correct code before filling number.

## Checkboxes (Marketing Opt-ins)
Always check that marketing checkboxes are UNCHECKED before submitting.
```bash
npx agent-browser --cdp 9222 eval "
  Array.from(document.querySelectorAll('input[type=checkbox]'))
    .filter(c => c.checked)
    .map(c => c.name || c.id || c.closest('label')?.textContent?.trim())
"
```
Uncheck any that relate to marketing/newsletters.

## Multi-step Checkout / Reservation Flows (generic pattern)
- Selection step: the options are usually cards in a list — snapshot first, then click the action button on the right card rather than the first one
- Details form: fields are often pre-filled from the logged-in account — always verify and correct name/email/phone against personalinfo.md
- Country select: usually a real `<select>` element — use `agent-browser select <ref> "<country>"` (read the user's country from personalinfo.md)
- Marketing checkbox near the bottom: must be unchecked (see above)
- Final submit: any button that completes a purchase or a binding booking — DO NOT click. Hand off to the user via the viewer for confirmation

## Event/Registration Forms (generic pattern)
- Gender: usually radio buttons
- DOB: three separate dropdowns (Day, Month, Year) or a date input — check with snapshot -i
- Nationality: dropdown — search for the user's nationality from personalinfo.md
- Emergency contact may be required — ask the user; never invent one
- Preference fields (sizes, dietary, etc.): ask the user if not in personalinfo.md
