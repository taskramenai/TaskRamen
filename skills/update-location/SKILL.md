# Update Location Skill

## Overview
Handle user requests to update their location (country, city, timezone). This updates
`VM_COUNTRY`, `USER_TIMEZONE`, and `VM_CITY` in `$CLAUDE_HOME/.env` so that other tools
and scripts can use location-aware defaults. `USER_TIMEZONE` is the user's wall-clock
zone (used by Claude to convert scheduled-task times); it is distinct from
`SYSTEM_TIMEZONE` (the host clock the scheduler runs in), which is detected at install.

## Trigger phrases
- "I moved to ...", "update my location to ...", "I'm in ... now", "change location to ..."
- Any message that implies the user wants to change their stored location

## Steps

1. **Parse the location** from the user's message (country, city, or both).
2. **Look up country code and timezone** using the mapping below (or `curl -sf https://ipinfo.io` for the VM's actual location if the user says "use current location").
3. **Update `$CLAUDE_HOME/.env`** — set or replace `VM_COUNTRY`, `USER_TIMEZONE`, and `VM_CITY` (also strip any legacy `VM_TIMEZONE` line):
   ```bash
   ENV_FILE="$CLAUDE_HOME/.env"
   # Remove old values if present (including the legacy VM_TIMEZONE key)
   sed -i '/^VM_COUNTRY=/d; /^USER_TIMEZONE=/d; /^VM_TIMEZONE=/d; /^VM_CITY=/d' "$ENV_FILE"
   # Append new values
   cat >> "$ENV_FILE" <<EOF
   VM_COUNTRY=<two-letter country code, e.g. US>
   USER_TIMEZONE=<IANA zone, e.g. America/New_York>
   VM_CITY=<city name>
   EOF
   ```
4. **Optionally re-run apt mirror switch** if the user asks or if the country changed.
   The mirror switch logic (from `install/deps.sh`) is:
   ```bash
   COUNTRY_LC=$(echo "$VM_COUNTRY" | tr '[:upper:]' '[:lower:]')
   MIRROR="${COUNTRY_LC}.archive.ubuntu.com"
   if curl -sf --max-time 4 "http://${MIRROR}/ubuntu/" >/dev/null 2>&1; then
       if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
           sudo sed -i "s|http://[a-z]*\.archive\.ubuntu\.com/ubuntu|http://${MIRROR}/ubuntu|g" \
               /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
       fi
       if [[ -f /etc/apt/sources.list ]]; then
           sudo sed -i "s|http://[a-z]*\.archive\.ubuntu\.com/ubuntu|http://${MIRROR}/ubuntu|g" \
               /etc/apt/sources.list 2>/dev/null || true
       fi
   fi
   ```
   Only do this if the user explicitly asks or if it's the first location setup.
5. **Re-anchor recurring tasks to the new wall clock.** Existing recurring tasks
   are stored in `SYSTEM_TIMEZONE` with a `UF=` intent tag recording the original
   wall-clock schedule. Default-zone tasks carry the `@USER` sentinel and follow
   `USER_TIMEZONE`; after changing it, run the resync job so "9am daily" still
   means 9am in the new zone:
   ```bash
   "$CLAUDE_HOME/core/tz-resync.sh"
   ```
   (Tasks scheduled with an explicit `--tz <zone>` stay pinned to that zone by
   design; one-time tasks and `--system-tz` tasks are left untouched. Run
   `core/tz-resync.sh --dry-run` first if you want to preview.)
6. **Confirm** back to the user via Telegram with the new values.

## Common location mapping

| Location | VM_COUNTRY | USER_TIMEZONE | VM_CITY |
|----------|------------|-------------|---------|
| Singapore | SG | Asia/Singapore | Singapore |
| Japan / Tokyo | JP | Asia/Tokyo | Tokyo |
| Japan / Osaka | JP | Asia/Tokyo | Osaka |
| Malaysia / KL | MY | Asia/Kuala_Lumpur | Kuala Lumpur |
| Thailand / Bangkok | TH | Asia/Bangkok | Bangkok |
| Indonesia / Jakarta | ID | Asia/Jakarta | Jakarta |
| Vietnam / HCMC | VN | Asia/Ho_Chi_Minh | Ho Chi Minh City |
| Philippines / Manila | PH | Asia/Manila | Manila |
| Taiwan / Taipei | TW | Asia/Taipei | Taipei |
| South Korea / Seoul | KR | Asia/Seoul | Seoul |
| Hong Kong | HK | Asia/Hong_Kong | Hong Kong |
| India / Mumbai | IN | Asia/Kolkata | Mumbai |
| India / Delhi | IN | Asia/Kolkata | Delhi |
| Australia / Sydney | AU | Australia/Sydney | Sydney |
| Australia / Melbourne | AU | Australia/Melbourne | Melbourne |
| UK / London | GB | Europe/London | London |
| Germany / Berlin | DE | Europe/Berlin | Berlin |
| France / Paris | FR | Europe/Paris | Paris |
| Netherlands / Amsterdam | NL | Europe/Amsterdam | Amsterdam |
| USA / New York | US | America/New_York | New York |
| USA / Los Angeles | US | America/Los_Angeles | Los Angeles |
| USA / San Francisco | US | America/Los_Angeles | San Francisco |
| Canada / Toronto | CA | America/Toronto | Toronto |
| UAE / Dubai | AE | Asia/Dubai | Dubai |

For unlisted locations, use a web search or `timedatectl list-timezones` to find the
correct IANA timezone, and use the ISO 3166-1 alpha-2 country code.

## Notes
- The user can always manually edit `.env` for edge cases.
- `USER_TIMEZONE` is the user's wall clock. The scheduling scripts
  (`core/schedule.sh`, `core/at-task.sh`, `core/list-tasks.sh`) read it and do
  all timezone conversion themselves — Claude passes times through verbatim. It
  does NOT change the system clock or `SYSTEM_TIMEZONE` (the zone the cron/`at`
  scheduler actually runs in, detected at install).
- Changing `USER_TIMEZONE` re-anchors existing **recurring** default-zone tasks
  (`@USER`-tagged) to the new wall clock once `core/tz-resync.sh` runs (step 5
  above, and it runs daily on its own). Explicit `--tz <zone>` tasks stay pinned
  to their named zone; one-time tasks keep their original absolute fire time.
