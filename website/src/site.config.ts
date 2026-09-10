/**
 * Everything on the page that is copy rather than layout.
 *
 * `version` is only the fallback now. The live download button reads the latest
 * release version from the GitHub API at build time, then points at the DMG in
 * Cloudflare R2. If GitHub cannot be reached, it uses this version instead. See
 * lib/release.ts. The DMG name follows the Makefile's
 * `$(APP_NAME)-$(VERSION).dmg`.
 */

const repo = 'https://github.com/BirjuVachhani/macq';
const version = '0.3.1';
const domain = 'macq.birju.dev';
const artifacts = 'https://artifacts.birju.dev/macq';

export const site = {
  name: 'MacQ',
  domain,
  url: `https://${domain}`,
  title: 'MacQ: menu-bar control for BenQ monitors',
  description:
    "Switch input, set brightness and volume on your BenQ monitor from the macOS menu bar. Under 5 MB, no bundled browser. Free and open source.",

  /** The 48px line at the top of the hero. No trailing period, by design. */
  headline: "Fast and lightweight menu-bar control for your BenQ monitor",

  /** Small print under the download button. */
  caption: 'Free and open source. Apple Silicon, macOS 14 or later',

  repo,
  version,
  /** A pill next to the version, for 'Alpha' and the like. Null hides it. */
  releaseStage: null as string | null,
  artifacts,
  download: `${artifacts}/MacQ-${version}.dmg`,

  /** Matches PRODUCT_BUNDLE_IDENTIFIER in app/MacQ.xcodeproj. The privacy page
      quotes it as the path to the preferences file MacQ writes. */
  bundleId: 'dev.birjuvachhani.macq',

  /** Credited at the foot of the page. */
  author: { name: 'Birju Vachhani', url: 'https://birju.dev' },

  nav: [{ label: 'GitHub', href: repo, style: 'outline' }] as const,

  /** Sits opposite the credit in the colophon, on every page. */
  legal: [
    { label: 'Privacy', href: '/privacy' },
    { label: 'Terms', href: '/terms' },
  ] as const,

  features: [
    { label: 'Tiny', desc: 'one native Swift process, about 4 MB on disk' },
    { label: 'Input switching', desc: 'USB-C, HDMI 1 and HDMI 2, one click away' },
    { label: 'Live sliders', desc: 'brightness and volume straight over DDC/CI' },
    { label: 'Source aliases', desc: 'rename HDMI 1 to MacBook, and it sticks' },
    { label: 'Launch at login', desc: 'off by default, one toggle in Settings' },
  ],
} as const;
