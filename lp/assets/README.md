# assets

`DelaGothicOne-subset.ttf` is the face drawn into the Open Graph card
(`src/app/[locale]/opengraph-image.tsx`). It is the same display face the site
uses for its headings, cut down to the characters the card actually shows.

Any character missing from it silently falls back to a different face, so when
the card's copy changes, rebuild the subset:

```sh
curl -sL -o /tmp/DelaGothicOne-Regular.ttf \
  "https://github.com/google/fonts/raw/main/ofl/delagothicone/DelaGothicOne-Regular.ttf"

pyftsubset /tmp/DelaGothicOne-Regular.ttf \
  --text="Hawky Claude Code is waiting. Hawky noticed. 待っている Claude Code に気付く。" \
  --unicodes="U+0020-007E" \
  --output-file=assets/DelaGothicOne-subset.ttf \
  --no-hinting --desubroutinize --layout-features=''
```
