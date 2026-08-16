/**
 * What the download button points at, resolved at build time.
 *
 * GitHub is asked what the latest release actually is, rather than trusting the
 * `version` in site.config.ts to have been bumped by hand. That config value
 * stays on as the fallback: a page that cannot reach the API should still ship
 * a working download rather than fail the build.
 *
 * This runs once per build, so the published page is only ever as fresh as its
 * last deploy. That is why the Pages workflow also triggers on `release:
 * published`, which rebuilds the site as soon as a new release exists.
 */

import { site } from '../site.config';

export interface Release {
  /** No leading `v`, matching the repository's tags. */
  version: string;
  /** Absolute URL of the .dmg. */
  download: string;
  /** Which of the two paths below produced this. */
  source: 'github' | 'fallback';
}

/** Shape of the one endpoint we read, narrowed to the fields we use. */
interface LatestReleaseResponse {
  tag_name?: string;
  assets?: Array<{ name?: string; browser_download_url?: string }>;
}

const ENDPOINT = 'https://api.github.com/repos/BirjuVachhani/macq/releases/latest';

/** Generous enough for a cold API, short enough not to hang a build behind it. */
const TIMEOUT_MS = 8000;

/** Astro renders the page more than once in dev, and the answer does not change. */
let inFlight: Promise<Release> | null = null;

async function fetchLatest(): Promise<Release> {
  const headers: Record<string, string> = {
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    // GitHub rejects API requests that do not identify themselves.
    'User-Agent': 'macq-website-build',
  };

  // Anonymous calls are capped at 60 an hour per IP, and CI runners share IPs
  // with every other project on the same host. The workflow hands its own token
  // in, which lifts the cap and makes the build's own rate limit private to it.
  const token = process.env.GITHUB_TOKEN;
  if (token) headers.Authorization = `Bearer ${token}`;

  const response = await fetch(ENDPOINT, {
    headers,
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });

  if (!response.ok) {
    throw new Error(`GitHub answered ${response.status} ${response.statusText}`);
  }

  const data = (await response.json()) as LatestReleaseResponse;

  const version = (data.tag_name ?? '').replace(/^v/, '').trim();
  if (!version) throw new Error('the latest release has no tag_name');

  // The release carries a `.dmg.sha256` checksum next to the disk image, and
  // that does not end in `.dmg`, so this picks the installer either way.
  const asset = data.assets?.find((candidate) => candidate.name?.endsWith('.dmg'));

  return {
    version,
    // Falling back to the conventional name covers a release published without
    // its asset attached yet, which is a real state during a release run.
    download:
      asset?.browser_download_url ??
      `${site.repo}/releases/download/${version}/MacQ-${version}.dmg`,
    source: 'github',
  };
}

export function loadRelease(): Promise<Release> {
  inFlight ??= fetchLatest().catch((error: unknown) => {
    const reason = error instanceof Error ? error.message : String(error);
    // Warn rather than throw. A stale download link is a much smaller problem
    // than a site that cannot be deployed because GitHub was briefly down.
    console.warn(
      `[release] Could not read the latest release (${reason}). ` +
        `Falling back to v${site.version} from site.config.ts.`,
    );
    return { version: site.version, download: site.download, source: 'fallback' as const };
  });

  return inFlight;
}
