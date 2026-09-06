# TaskRamen Tips

A pool of short usage tips. TaskRamen sends one of these to the user once right
after the first-boot welcome, and one per day (an 8am recurring task created by
the installer asks Claude to send a random tip from this file).

How to use this file when asked to send a random tip:
- Each tip starts with a `## Tip:` heading; they are numbered in file order
  (1st `## Tip:` heading = tip 1, 2nd = tip 2, etc.).
- Do NOT count the tips yourself by reading the file — that's unreliable. Run
  this exact command to get the count:
  `grep -c '^## Tip:' "$CLAUDE_HOME/docs/tips.md"`
- Get an actually random pick — do NOT just eyeball one or default to the
  first/most memorable tip. Run this exact command, using the count from the
  step above as N, and use the number it prints:
  `shuf -i 1-N -n 1`
  If that number lands on a tip excluded by the best-effort rule below,
  re-run the `shuf` command until it doesn't.
- Run this exact command to extract the body of the tip at that number
  (replacing N with the selected number):
  `awk -v n=N '/^## Tip:/ {count++} /^---/ && count==n {exit} count==n {print}' "$CLAUDE_HOME/docs/tips.md"`
  Send that exact output to the user over Telegram. Just the tip — no
  preamble or extra commentary.
- Best-effort skip: if you can easily tell a capability is already set up, try
  to avoid sending the tip that suggests connecting it — skip
  **"Connect a Google account"** if Google is already connected, and skip
  **"Unlock web search, maps and flights"** if SerpApi / web search is already
  connected. This is nice-to-have, not critical; if you're unsure, just send any
  random tip.

Every tip ends with the same line:
`For more tips and usage examples, visit [www.taskramen.ai](https://www.taskramen.ai)`

---

## Tip: Projects keep your bigger work organised

For anything ongoing or worth keeping, ask me to start a project. I'll create a
dedicated folder and remember the context, files, and instructions across days —
so you can come back to it any time. For example: *"Start a project to compile
corporate client leads for my personal training business, call it PTleadgen."*
After that, just refer to it by name — *"Add today's leads to PTleadgen"* — and
I'll pick up right where we left off.

For more tips and usage examples, visit [www.taskramen.ai](https://www.taskramen.ai)

---

## Tip: Connect a Google account

Give me a Google account and I can send and receive email on your behalf, create
Google Docs, Sheets and Slides, and send calendar invites — all from a simple
Telegram message. Just say *"Connect Google"* and I'll walk you through a quick,
secure setup. After that, try *"Email the Q3 report to my accountant"* or
*"Put dentist Thursday 3pm on my calendar."*

For more tips and usage examples, visit [www.taskramen.ai](https://www.taskramen.ai)

---

## Tip: I work with your Office files

Send me a PowerPoint, Word, Excel, or PDF over Telegram and I'll work on it
directly — build a slide deck, fill in a spreadsheet, redraft a document, or pull
data out of a PDF. Just attach the file and tell me what you'd like done, e.g.
*"Tidy up this deck and add a summary slide"* or *"Turn this spreadsheet into a
chart."* I'll send the finished file straight back to you.

For more tips and usage examples, visit [www.taskramen.ai](https://www.taskramen.ai)

---

## Tip: I can build and host a website for you

Describe the site you want — a personal page, a small business site, a landing
page — and I'll build it and get it hosted on the web, then send you the link.
For example: *"Build me a one-page site for my personal training business with my
services and a contact form."* Want changes later? Just tell me and I'll update
the live site.

For more tips and usage examples, visit [www.taskramen.ai](https://www.taskramen.ai)

---

## Tip: Simple reminders, whenever you need them

I can remind you about anything at a set time. Just say *"Remind me at 9am to
pick up the laundry"* or *"Remind me in 2 hours to call the plumber"* and the
reminder will land in Telegram right on time. No app, no setup — just ask.

For more tips and usage examples, visit [www.taskramen.ai](https://www.taskramen.ai)

---

## Tip: Powerful recurring tasks, on autopilot

Beyond simple reminders, I can run whole tasks for you on a schedule. For
example: *"Every day at 8am, run the PTleadgen project and send me the new
leads"* or *"Every Monday morning, summarise my unread emails."* I'll do the work
and send you the result — automatically, every time.

For more tips and usage examples, visit [www.taskramen.ai](https://www.taskramen.ai)

---

## Tip: Unlock web search, maps and flights

For advanced, up-to-the-minute Google Search, Maps and Flights lookups, I can
use SerpApi. Once it's connected I can do things like *"Find the cheapest flight
to Tokyo next month"* or *"What are the best-rated cafes near me?"*
Just ask me to help you connect *"SerpApi"* and I'll guide you through it.

For more tips and usage examples, visit [www.taskramen.ai](https://www.taskramen.ai)

---

## Tip: Telegram is your control panel

Everything happens right here in Telegram — text me, send me files, or forward me
something to act on. You don't need to keep a terminal open or learn any
commands; just talk to me naturally, the way you would a capable assistant.

For more tips and usage examples, visit [www.taskramen.ai](https://www.taskramen.ai)

---

## Tip: I restart at 3am — keep work in projects

TaskRamen restarts Claude at 3am every night to stay fresh. Anything saved in a
project is kept safe across the restart, so for work you care about, ask me to
store it in a project. One-off chats may not survive the nightly restart, but
projects always will.

For more tips and usage examples, visit [www.taskramen.ai](https://www.taskramen.ai)

---

## Tip: Check in on what I'm doing

If I'm running a longer task in the background, you can ask *"What's the status?"*
any time and I'll tell you where things stand. You can also ask me to list your
scheduled reminders and tasks, or to cancel any of them — just ask in plain
language.

For more tips and usage examples, visit [www.taskramen.ai](https://www.taskramen.ai)
