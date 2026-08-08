// @ts-check
import { defineConfig } from 'astro/config';

// The site is served from the root of its own subdomain, so there is no base
// path. `site` is only used to build absolute URLs for the canonical link and
// the Open Graph tags.
export default defineConfig({
  site: 'https://macq.birju.dev',
  build: {
    // One page, no client JS: emit `index.html` rather than a directory.
    format: 'file',
  },
});
