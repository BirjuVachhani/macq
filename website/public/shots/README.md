# App shots

Drop screenshots or short screen recordings here and they appear in the site's
carousel, sorted by filename. Nothing else needs editing.

Until this folder has real files in it, the carousel renders placeholder tiles,
so the layout still reads while you gather assets.

## Naming

Number the files so the order is explicit, and let the rest of the name describe
the shot. The name becomes the alt text: `02-brightness-slider.png` reads as
"MacQ, brightness slider".

```
01-sources.png
02-brightness-slider.png
03-settings-aliases.mp4
```

Files starting with `.` are ignored, and so is this README.

## Format

- Images: `.png`, `.jpg`, `.webp`, `.avif`, `.gif`
- Video: `.mp4`, `.webm`, `.mov`. Videos autoplay muted and loop, so keep them
  short and silent. H.264 in an `.mp4` is the safe choice for Safari.

Tiles are 16:10. Shots at that ratio fill a tile exactly; anything else is
center-cropped to fit.

About two or three tiles are visible at once in a desktop window, and one on a
phone. Six to nine is a good target: enough that the strip is worth scrolling,
few enough that every shot earns its place.

## Where these came from

The `.webp` files here are built from the full-resolution originals in
[../../screenshots/](../../screenshots/), which sit outside `public/` so they
are not shipped to visitors. A tile never renders wider than about 800 CSS
pixels, so 1600px is already retina, and WebP at q90 is visually identical to
the PNG at a fraction of the weight (5.7 MB of PNG became 472 KB).

```sh
cd website
for f in screenshots/*.png; do
  magick "$f" -resize 1600x -quality 90 "public/shots/$(basename "$f" .png).webp"
done
```
