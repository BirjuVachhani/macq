#!/usr/bin/env bash
#
# Set the release version everywhere it is written down by hand.
#
#   ./set_version.sh 1.2.0          set the version, leave the build number
#   ./set_version.sh 1.2.0 7        set both
#   ./set_version.sh 1.2.0 inc      set the version, increment the build number
#   ./set_version.sh 1.2.0 ++       same as inc
#
# Three files are edited:
#
#   app/MacQ.xcodeproj/project.pbxproj   MARKETING_VERSION, CURRENT_PROJECT_VERSION
#   website/src/site.config.ts           the download-link fallback
#   website/package.json (+ lock)        the site's own package version
#
# Everything else derives from those. MacQ/Info.plist refers to
# $(MARKETING_VERSION) and $(CURRENT_PROJECT_VERSION), the Makefile reads
# MARKETING_VERSION back out of the project to name the DMG, and site.config.ts
# builds `download` from `version`, so none of them need touching here.
#
# The website's download button asks the GitHub API what the latest release is
# and only falls back to site.config.ts when it cannot reach it (see
# website/src/lib/release.ts). The fallback is still kept in step, because a
# stale one points at a .dmg that was never uploaded.
#
# Every target is checked before any of them is written, so a version that
# cannot be applied cleanly leaves the tree untouched rather than half bumped.
#
# `make version` prints what the next build will use.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PBXPROJ="$SCRIPT_DIR/app/MacQ.xcodeproj/project.pbxproj"
WEBSITE_DIR="$SCRIPT_DIR/website"
SITE_CONFIG="$WEBSITE_DIR/src/site.config.ts"

die() {
	echo "error: $*" >&2
	exit 1
}

warn() {
	echo "warning: $*" >&2
}

usage() {
	cat >&2 <<'EOF'
usage: set_version.sh <version> [build-number|inc|++]

  <version>       marketing version, e.g. 1.2.0
  <build-number>  integer build number. "inc" or "++" increments the current
                  one. Omit it to leave the build number as it is.

examples:
  ./set_version.sh 0.2.0
  ./set_version.sh 0.2.0 2
  ./set_version.sh 0.2.0 inc
  ./set_version.sh 0.2.0 ++
EOF
	exit 2
}

# First value of a build setting, with any surrounding quotes removed.
read_setting() {
	sed -n "s/^[[:space:]]*$1 = \(.*\);/\1/p" "$PBXPROJ" | head -1 | tr -d '"'
}

# How many build configurations declare it (Debug and Release both do).
count_setting() {
	grep -c "^[[:space:]]*$1 = .*;" "$PBXPROJ" || true
}

# The `const version = '...'` line in site.config.ts.
SITE_VERSION_RE="^const version = '[^']*';$"

read_site_version() {
	sed -n "s/^const version = '\([^']*\)';$/\1/p" "$SITE_CONFIG" | head -1
}

# Root "version" of a package manifest. It is the first such key npm writes, and
# these files are ours, so the first match is the package's own version rather
# than a dependency's.
read_package_version() {
	sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1
}

TMP=""
trap 'rm -f "$TMP"' EXIT

# Replace whole lines in $1 using the sed script in $2, refusing to write if the
# line count changed: only whole-line substitutions are ever made here, so a
# different shape means the edit went somewhere unintended.
rewrite_lines() {
	local file="$1" script="$2"
	TMP="$(mktemp -t set_version)"

	sed -e "$script" "$file" > "$TMP"
	[ "$(wc -l < "$TMP")" -eq "$(wc -l < "$file")" ] ||
		die "refusing to write $file: the line count changed"

	if [ "${file##*.}" = "pbxproj" ]; then
		plutil -lint "$TMP" > /dev/null 2>&1 ||
			die "refusing to write $file: the result is not a readable project file"
	fi

	# Copy rather than move, to keep the file's permissions and inode: Xcode may
	# have the project open and watching it.
	cat "$TMP" > "$file"
	rm -f "$TMP"
	TMP=""
}

case "${1:-}" in
	-h | --help | help | '') usage ;;
esac
[ "$#" -le 2 ] || usage

version="$1"
build_arg="${2:-}"

# ---------------------------------------------------------------- validate

# The pbxproj holds these unquoted, so keep the version to characters that are
# safe there. Apple additionally expects CFBundleShortVersionString to be one to
# three dot-separated integers, which is a warning rather than an error: a
# prerelease version still builds and still notarizes.
[[ $version =~ ^[A-Za-z0-9._+-]+$ ]] ||
	die "invalid version '$version': letters, digits, dot, plus, minus and underscore only"
if ! [[ $version =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
	warn "'$version' is not one to three dot-separated integers, which is
         what Apple expects for CFBundleShortVersionString."
fi

[ -f "$PBXPROJ" ] || die "Xcode project not found: $PBXPROJ"
[ -f "$SITE_CONFIG" ] || die "site config not found: $SITE_CONFIG"

current_version="$(read_setting MARKETING_VERSION)"
current_build="$(read_setting CURRENT_PROJECT_VERSION)"
[ -n "$current_version" ] || die "no MARKETING_VERSION in $PBXPROJ"
[ -n "$current_build" ] || die "no CURRENT_PROJECT_VERSION in $PBXPROJ"

# Exactly one declaration, or the substitution below would silently edit a line
# that is not the one this script means.
site_matches="$(grep -c "$SITE_VERSION_RE" "$SITE_CONFIG" || true)"
[ "$site_matches" -eq 1 ] ||
	die "expected exactly one \"const version = '...';\" in $SITE_CONFIG, found $site_matches"
current_site_version="$(read_site_version)"

case "$build_arg" in
	'')
		build="$current_build"
		;;
	inc | ++)
		[[ $current_build =~ ^[0-9]+$ ]] ||
			die "cannot increment build number '$current_build': it is not an integer"
		build=$((current_build + 1))
		;;
	*)
		[[ $build_arg =~ ^[0-9]+$ ]] ||
			die "invalid build number '$build_arg': expected an integer, \"inc\" or \"++\""
		build="$build_arg"
		;;
esac

# ------------------------------------------------------------------- apply

rewrite_lines "$PBXPROJ" \
"s/^\([[:space:]]*\)MARKETING_VERSION = .*;/\1MARKETING_VERSION = $version;/
s/^\([[:space:]]*\)CURRENT_PROJECT_VERSION = .*;/\1CURRENT_PROJECT_VERSION = $build;/"

new_version="$(read_setting MARKETING_VERSION)"
new_build="$(read_setting CURRENT_PROJECT_VERSION)"
[ "$new_version" = "$version" ] && [ "$new_build" = "$build" ] ||
	die "the project still reads $new_version ($new_build); nothing was applied"

rewrite_lines "$SITE_CONFIG" "s/$SITE_VERSION_RE/const version = '$version';/"

new_site_version="$(read_site_version)"
[ "$new_site_version" = "$version" ] ||
	die "$SITE_CONFIG still reads $new_site_version; nothing was applied"

# The site's package version is private metadata, never published and never read
# by the page, so it must not be the thing that blocks a release. npm owns both
# the manifest and the lockfile, so it does this rather than another sed.
package_note=""
current_package_version=""
if [ -f "$WEBSITE_DIR/package.json" ]; then
	current_package_version="$(read_package_version "$WEBSITE_DIR/package.json")"
	if [ "$current_package_version" = "$version" ]; then
		package_note="already $version"
	elif command -v npm > /dev/null 2>&1; then
		if (cd "$WEBSITE_DIR" &&
			npm version "$version" --no-git-tag-version --allow-same-version > /dev/null 2>&1); then
			package_note="$current_package_version -> $version"
		else
			package_note="unchanged, npm version failed"
			warn "could not update $WEBSITE_DIR/package.json; set it by hand"
		fi
	else
		package_note="unchanged, npm not installed"
		warn "npm is not installed, so package.json and package-lock.json still
         read $current_package_version. The app and the site config are set."
	fi
fi

# ----------------------------------------------------------------- summary

printf '==> MacQ %s (%s)\n' "$version" "$build"
printf '    MARKETING_VERSION        %-24s %s\n' \
	"$current_version -> $version" "$(count_setting MARKETING_VERSION) build configurations"
if [ "$build" = "$current_build" ]; then
	printf '    CURRENT_PROJECT_VERSION  %-24s %s\n' \
		"$build (unchanged)" "$(count_setting CURRENT_PROJECT_VERSION) build configurations"
else
	printf '    CURRENT_PROJECT_VERSION  %-24s %s\n' \
		"$current_build -> $build" "$(count_setting CURRENT_PROJECT_VERSION) build configurations"
fi
printf '    site.config.ts           %-24s %s\n' \
	"$current_site_version -> $version" "download link fallback"
if [ -n "$package_note" ]; then
	printf '    website package.json     %-24s %s\n' "$package_note" "and package-lock.json"
fi
