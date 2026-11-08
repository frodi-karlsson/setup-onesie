# shellcheck shell=bash
# Holds the helpers that install.sh and run.sh share, and the onesie releases setup-onesie supports. Source it, do not run it.

# The oldest onesie release setup-onesie supports, and the first it does not. Empty means no upper bound, and a bound names a minor, such as 0.15.0.
min_version=0.12.0
below_version=

die() {
	annotate error "$*"
	exit 1
}

annotate() {
	local level="$1" message="$2"
	message="${message//%/%25}"
	message="${message//$'\r'/%0D}"
	message="${message//$'\n'/%0A}"
	echo "::$level::$message"
}

supported_range() {
	local extra
	min="$min_version"
	below="$below_version"
	[ -n "${SETUP_ONESIE_TEST_RANGE:-}" ] || return 0

	read -r min below extra <<<"$SETUP_ONESIE_TEST_RANGE"
	[[ "$min" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ -z "$below" || "$below" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ -z "$extra" ] ||
		die "SETUP_ONESIE_TEST_RANGE must be MIN or MIN BELOW, each a version such as 0.12.0, not $SETUP_ONESIE_TEST_RANGE"
}

no_release_message() {
	local min="$1" below="$2" newest="$3" message
	if [ -n "$below" ]; then
		message="no onesie release between $min and $below was found"
	else
		message="no onesie release of $min or later was found"
	fi
	echo "$message.${newest:+ Pin a version such as ${newest#v}}"
}

outside_range_message() {
	local version="${1#v}" min="$2" below="$3"
	if [ -n "$below" ]; then
		echo "onesie $version is outside the range setup-onesie supports, $min up to $below"
	else
		echo "onesie $version is outside the range setup-onesie supports, $min or later"
	fi
}

release_lines() {
	{ grep -oE '"(tag_name|draft|prerelease)"[[:space:]]*:[[:space:]]*("[^"]*"|true|false)' || true; } |
		awk -F'"' '
			$2 == "tag_name" { tag = $4; seen++ }
			$2 == "draft" { draft = ($0 ~ /true$/) ? "true" : "false"; seen++ }
			$2 == "prerelease" { prerelease = ($0 ~ /true$/) ? "true" : "false"; seen++ }
			seen == 3 { print tag, draft, prerelease; seen = 0 }
		'
}

pick_release() {
	local min="$1" below="$2" best="" tag draft prerelease
	while read -r tag draft prerelease; do
		[ "$draft" = "false" ] && [ "$prerelease" = "false" ] || continue
		[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
		in_range "$tag" "$min" "$below" || continue
		[ -z "$best" ] || version_below "$best" "$tag" || continue
		best="$tag"
	done
	echo "$best"
}

in_range() {
	! version_below "$1" "$2" && { [ -z "$3" ] || version_below "$1" "$3"; }
}

version_below() {
	local a b i
	IFS=. read -r -a a <<<"$(core "$1")"
	IFS=. read -r -a b <<<"$(core "$2")"
	for i in 0 1 2; do
		if ((10#${a[i]} != 10#${b[i]})); then
			((10#${a[i]} < 10#${b[i]}))
			return
		fi
	done
	return 1
}

core() {
	local version="${1#v}"
	echo "${version%%-*}"
}
