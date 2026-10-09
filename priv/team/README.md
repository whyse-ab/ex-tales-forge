# Founders' page data

`data.json` is a snapshot of tales-forge-docs `docs/team-page/data.json`, the
numbers behind the founders' pages: the landing page at `/team`
(`TalesForgeWeb.TeamLive`) and the full presentation at `/team/presentation`
(`TalesForgeWeb.TeamPresentationLive`). The copy comes from
`docs/team-page/content.md` in the same folder (section 6, the shared board,
from `shared_board`, is `TalesForgeWeb.TeamBoard`).

It is read **at compile time** by `TalesForge.TeamPage` (`@external_resource`):
no file or network IO on a request, a broken file fails the build and CI
instead of the page, and the tests check the exact file that ships. A `null`
or missing value shows as "not measured yet"; never put a guess in.

To refresh the numbers, copy the docs file and open a PR:

    cp ../tales-forge-docs/docs/team-page/data.json priv/team/data.json

Both pages show `_about.as_of` in their footer ("Numbers as of ...").

## Illustrations

The painted illustrations come from tales-forge-docs `docs/team-page/images/`
(approved by Fredrik) and are served from `priv/static/images/team/` by
`TalesForgeWeb.TeamArt.picture/1`: WebP with a JPEG fallback, one file per
width for `srcset`, explicit `width`/`height`, lazy loading below the fold.
The files are generated once and committed; nothing runs at build time.

| Picture | Used for | Crop of the 1280×720 original | Widths |
|---|---|---|---|
| `hero` | the hero at the top | none (16:9) | 480, 960, 1280 |
| `case`, `bobby`, `gentry` | the bots' cards | centred 960×720 (4:3) | 320, 640, 960 |
| `founders-seal` | the "A founder's OK" steps of the flow | 660×660 at +320+10 (the seal) | 96, 192 |

No width above the original's: upscaling adds bytes, not detail. To redo
them (ImageMagick 7 and cwebp), from the repo root with the docs checkout next
to it:

    SRC=../tales-forge-docs/docs/team-page/images OUT=priv/static/images/team T=$(mktemp -d)
    convert $SRC/hero.jpg $T/hero.png
    for b in case bobby gentry; do convert $SRC/$b.jpg -gravity center -crop 960x720+0+0 +repage $T/$b.png; done
    convert $SRC/founders-seal.jpg -crop 660x660+320+10 +repage $T/founders-seal.png
    gen() { n=$1; shift; for w in "$@"; do
      convert $T/$n.png -filter Lanczos -resize ${w}x $T/$n-$w.png
      convert $T/$n-$w.png -strip -sampling-factor 4:2:0 -interlace JPEG -quality 78 $OUT/$n-$w.jpg
      cwebp -quiet -q 72 -m 6 -sharp_yuv -metadata none $T/$n-$w.png -o $OUT/$n-$w.webp
    done; }
    gen hero 480 960 1280; for b in case bobby gentry; do gen $b 320 640 960; done; gen founders-seal 96 192

Like every file under `priv/static/images`, they can be fetched without
signing in (the page itself still needs the team sign-in).
