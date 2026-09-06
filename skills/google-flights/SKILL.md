# Google Flights Skill

## SerpAPI (preferred)
```
engine: google_flights
departure_id: JFK (IATA code -- origin; use the user's home airport)
arrival_id: NRT (IATA code -- use NRT/HND not TYO)
outbound_date: 2026-05-30
type: 2 (one-way)
stops: 1 (nonstop)
currency: USD (use the user's currency, from personalinfo.md country)
```

## Browser Fallback
```
https://www.google.com/travel/flights
```
Set One Way -> origin/dest -> date -> filter Nonstop.
Results in `li` inside `ul[aria-label*="Flights"]`.

## Rules
- `departure_id`/`arrival_id` must be IATA codes, and must be **airport** codes,
  not metropolitan-area codes. A city code such as `TYO` (Tokyo) or `LON`
  (London) returns nothing — query each airport separately (`NRT` and `HND`,
  `LHR`/`LGW`/`STN`) and merge the results.
- Prefer the SerpAPI engine over scraping a flight-search site. Most aggregators
  block automated access; if one serves a bot-check page, treat it as a dead end
  for that session rather than retrying (see `docs/websites.md`).
