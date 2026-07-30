# Pixel Hearts 💗

A two-player pixel draw-and-guess game for Christian & girlfriend.
One person draws a secret word on a 16×16 pixel grid, texts a link, the other guesses.

## The loop

1. Pick 1 of 3 random secret words (drawn from 6 categories, ~110 words)
2. Draw it on the 16×16 grid — 15 colors, pencil / fill / eraser / undo / clear
3. Tap **Send** → native share sheet or copy link
4. They open the link: drawing reveals pixel-by-pixel, category is the only hint
5. 4 guesses, one letter revealed per miss, fuzzy matching on typos/plurals
6. Result screen → they send the outcome back → your turn to draw

## How it works with no server

The entire round is encoded into the URL hash, so there is nothing to host
beyond one static file and no account to create.

- 16×16 grid, 15 colors + transparent → 4 bits per pixel
- Run-length encoded (1 byte per run: `color << 4 | runLength-1`)
- Wrapped in compact JSON, XOR-scrambled, base64url'd into the hash

Typical link is **~180 characters**; the pathological worst case (every pixel
alternating) is **581**. Both fit in an iMessage with room to spare.

The XOR scramble is an anti-spoiler measure, not security — it stops the answer
from showing up if someone idly base64-decodes the link or a preview unfurls it.

Scores and streak live in `localStorage`, per device. The gallery is shared —
see below.

## Shared gallery (the profile)

Two phones holding the same **pair code** see one gallery. The code is 16
random url-safe characters generated on-device; the invite link carries it so
the other phone joins on first open, and any game link doubles as an invite.

Rounds sync through Supabase. The client never touches the table directly:

| function | who calls it | what it does |
|---|---|---|
| `ph_add_round` | artist on send, guesser on open | registers the round (idempotent) |
| `ph_finish_round` | guesser on result | writes outcome, tries, guesser |
| `ph_get_rounds` | gallery screen | returns that pair's rounds |

The table has RLS on with **zero policies** and permissions revoked, so the
public anon key grants nothing by itself. Every function requires the pair
code and refuses anything under 12 characters. Wrong code returns nothing and
writes nothing — verified.

Every cloud call is best-effort and wrapped: with no network, or with the keys
left blank, the game plays exactly as before and the gallery falls back to
whatever is on that phone.

### Setting it up

1. Create a free project at supabase.com
2. SQL Editor → paste `supabase/schema.sql` → Run
3. Settings → API → copy the **Project URL** and the **anon public** key
4. Put them in `index.html`:

```js
const SUPABASE_URL      = 'https://xxxxxxxx.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGci...';
```

Both are safe to commit — that is what the anon key is for, and the schema is
built on the assumption it is public.

## Running it

It is one self-contained file. Open `index.html` in any browser, or serve it:

```sh
python3 -m http.server 8899   # then http://localhost:8899
```

For phone-to-phone play it needs a public URL (see deploy notes below), because
the link you text has to open somewhere. Once it is hosted, both of you should
"Add to Home Screen" — it is configured to launch fullscreen like a real app.

## Tests

Encoding round-trip and guess-matching were verified with throwaway node
scripts (407 grid cases, 23 matcher cases, all passing). They are not kept in
the repo — the logic lives inline in `index.html`.

## Tweaking

Everything is in `index.html`:

- `WORDS` — the word bank, grouped by category
- `PAL` — the 15-color palette (index 0 is transparent)
- `N` — grid size, currently 16 (changing it breaks existing links)
- `MAX_TRIES` — guesses allowed, currently 4
