/**
 * The right-hand column of app shots.
 *
 * Files dropped into `public/shots/` show up on the page automatically, sorted
 * by filename, so `01-sources.png`, `02-brightness.mp4` and so on land in the
 * order you name them. Until there are any, the column renders placeholder
 * tiles so the layout still reads.
 *
 * The tiles are `1920 / 1206`, matching a 16:10 window with its title bar, so
 * shots at that ratio fill a tile without being cropped.
 */

import fs from 'node:fs';
import path from 'node:path';

const SHOTS_DIR = path.join(process.cwd(), 'public', 'shots');

const VIDEO_EXTENSIONS = new Set(['.mp4', '.webm', '.mov']);
const IMAGE_EXTENSIONS = new Set(['.png', '.jpg', '.jpeg', '.webp', '.avif', '.gif']);

/** How many placeholders to draw when `public/shots/` is empty. */
const PLACEHOLDER_COUNT = 9;

export type Shot =
  | { kind: 'video'; src: string; alt: string }
  | { kind: 'image'; src: string; alt: string }
  | { kind: 'placeholder' };

/**
 * Turn `02-brightness-slider.png` into "MacQ, brightness slider" so the alt
 * text and the video label say something useful without a separate manifest.
 */
function altFromFilename(filename: string): string {
  const words = path
    .basename(filename, path.extname(filename))
    .replace(/^[\d]+[-_ ]*/, '')
    .replace(/[-_]+/g, ' ')
    .trim();

  return words ? `MacQ, ${words}` : 'MacQ screenshot';
}

export function loadShots(): Shot[] {
  let filenames: string[];
  try {
    filenames = fs.readdirSync(SHOTS_DIR);
  } catch {
    // No `public/shots/` at all. Same outcome as an empty one.
    filenames = [];
  }

  const shots = filenames
    .filter((name) => !name.startsWith('.'))
    .sort((a, b) => a.localeCompare(b, 'en', { numeric: true }))
    .flatMap((name): Shot[] => {
      const extension = path.extname(name).toLowerCase();
      const src = `/shots/${name}`;
      const alt = altFromFilename(name);

      if (VIDEO_EXTENSIONS.has(extension)) return [{ kind: 'video', src, alt }];
      if (IMAGE_EXTENSIONS.has(extension)) return [{ kind: 'image', src, alt }];
      return [];
    });

  if (shots.length > 0) return shots;

  return Array.from({ length: PLACEHOLDER_COUNT }, (): Shot => ({ kind: 'placeholder' }));
}
