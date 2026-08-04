#!/usr/bin/env bash
#
# Set the marketing version and build number of the Xcode project.
#
#   ./set_version.sh 1.2.0          set the version, leave the build number
#   ./set_version.sh 1.2.0 7        set both
#   ./set_version.sh 1.2.0 inc      set the version, increment the build number
#   ./set_version.sh 1.2.0 ++       same as inc
#
# MARKETING_VERSION and CURRENT_PROJECT_VERSION are project-level build
# settings, and MacQ/Info.plist refers to them as $(MARKETING_VERSION) and
# $(CURRENT_PROJECT_VERSION), so changing them here is enough: Xcode builds,
# `make build` and `make release` all pick the new values up.
#
# `make version` prints what the next build will use.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PBXPROJ="$SCRIPT_DIR/app/MacQ.xcodeproj/project.pbxproj"

die() {
	echo "error: $*" >&2
	exit 1
}

usage() {
	cat >&2 <<'EOF'
usage: set_version.sh <version> [build-number|inc|++]

  <version>       marketing version, e.g. 1.2.0
  <build-number>  integer build number. "inc" or "++" increments the current
                  one. Omit it to leave the build number as it is.

examples:
  ./set_version.sh 0.1.0
  ./set_version.sh 0.1.0 2
  ./set_version.sh 0.1.0 inc
  ./set_version.sh 0.1.0 ++
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

case "${1:-}" in
	-h | --help | help | '') usage ;;
esac
[ "$#" -le 2 ] || usage

version="$1"
build_arg="${2:-}"

[ -f "$PBXPROJ" ] || die "Xcode project not found: $PBXPROJ"

# The pbxproj holds these unquoted, so keep the version to characters that are
# safe there. Apple additionally expects CFBundleShortVersionString to be one to
# three dot-separated integers, which is a warning rather than an error: a
# prerelease version still builds and still notarizes.
[[ $version =~ ^[A-Za-z0-9._+-]+$ ]] ||
	die "invalid version '$version': letters, digits, dot, plus, minus and underscore only"
if ! [[ $version =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
	echo "warning: '$version' is not one to three dot-separated integers, which is" >&2
	echo "         what Apple expects for CFBundleShortVersionString." >&2
fi

current_version="$(read_setting MARKETING_VERSION)"
current_build="$(read_setting CURRENT_PROJECT_VERSION)"
[ -n "$current_version" ] || die "no MARKETING_VERSION in $PBXPROJ"
[ -n "$current_build" ] || die "no CURRENT_PROJECT_VERSION in $PBXPROJ"

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

tmp="$(mktemp -t set_version)"
trap 'rm -f "$tmp"' EXIT

sed -e "s/^\([[:space:]]*\)MARKETING_VERSION = .*;/\1MARKETING_VERSION = $version;/" \
	-e "s/^\([[:space:]]*\)CURRENT_PROJECT_VERSION = .*;/\1CURRENT_PROJECT_VERSION = $build;/" \
	"$PBXPROJ" > "$tmp"

# Only whole-line substitutions were made, so anything that changed the shape of
# the file means the edit went wrong. Better to bail out than to hand Xcode a
# broken project.
[ "$(wc -l < "$tmp")" -eq "$(wc -l < "$PBXPROJ")" ] ||
	die "refusing to write: the line count changed"
plutil -lint "$tmp" > /dev/null 2>&1 ||
	die "refusing to write: the result is not a readable project file"

# Copy rather than move, to keep the file's permissions and inode: Xcode may
# have the project open and watching it.
cat "$tmp" > "$PBXPROJ"

new_version="$(read_setting MARKETING_VERSION)"
new_build="$(read_setting CURRENT_PROJECT_VERSION)"
[ "$new_version" = "$version" ] && [ "$new_build" = "$build" ] ||
	die "the project still reads $new_version ($new_build); nothing was applied"

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
