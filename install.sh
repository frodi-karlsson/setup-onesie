#!/usr/bin/env bash
# Installs a verified onesie release for a GitHub Actions job, configured by the inputs in action.yml.

repo="frodi-karlsson/onesie"
signer_workflow="frodi-karlsson/onesie/.github/workflows/release.yml"

main() {
	set -euo pipefail

	check_runner
	check_inputs
	platform
	resolve_version

	tmp="$(mktemp -d "$RUNNER_TEMP/setup-onesie.XXXXXX")"
	trap 'rm -rf "$tmp"' EXIT

	install
	smoke_test "$dir"

	echo "$dir" >>"$GITHUB_PATH"
	echo "version=${version#v}" >>"$GITHUB_OUTPUT"
}

check_runner() {
	local name
	for name in RUNNER_OS RUNNER_ARCH RUNNER_TEMP RUNNER_TOOL_CACHE GITHUB_PATH GITHUB_OUTPUT; do
		[ -n "${!name:-}" ] || die "$name is not set, so install.sh is not running as a GitHub Actions step"
	done
}

check_inputs() {
	case "${INPUT_VERIFY_PROVENANCE:-true}" in
	true | false) ;;
	*) die "verify-provenance must be true or false" ;;
	esac

	base_url="${INPUT_RELEASE_BASE_URL:-}"
	base_url="${base_url%/}"
	case "$base_url" in
	"" | https://* | file://*) ;;
	*) die "release-base-url must start with https:// or file://" ;;
	esac
}

platform() {
	case "$RUNNER_OS" in
	Linux) os="linux" ;;
	macOS) os="darwin" ;;
	Windows) os="windows" ;;
	*) die "onesie has no release archive for $RUNNER_OS on $RUNNER_ARCH" ;;
	esac

	case "$RUNNER_ARCH" in
	X64) arch="amd64" ;;
	ARM64) arch="arm64" ;;
	*) die "onesie has no release archive for $RUNNER_OS on $RUNNER_ARCH" ;;
	esac
}

resolve_version() {
	version="${INPUT_VERSION:-latest}"

	if [ "$version" = "latest" ]; then
		[ -z "$base_url" ] ||
			die "release-base-url needs a version, since a mirror cannot say which release is latest"
		latest_tag
	fi

	case "$version" in
	v*) ;;
	*) version="v$version" ;;
	esac

	[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] ||
		die "$version is not a onesie version. Use latest or a release such as 0.12.0"
}

latest_tag() {
	version=""
	if [ -n "${GH_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
		local attempt
		for attempt in 1 2 3; do
			version="$(gh api "repos/$repo/releases/latest" --jq .tag_name)" && break
			version=""
			[ "$attempt" -eq 3 ] || sleep "$attempt"
		done
	else
		local auth=()
		[ -z "${GH_TOKEN:-}" ] || auth=(-H "Authorization: Bearer $GH_TOKEN")
		version="$(curl -fsSL --retry 3 ${auth[@]+"${auth[@]}"} --url "https://api.github.com/repos/$repo/releases/latest" |
			sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')" || version=""
	fi

	[ -n "$version" ] || die "could not ask GitHub for the latest onesie release"
}

install() {
	dir="$RUNNER_TOOL_CACHE/onesie/${version#v}/$arch"
	if [ -f "$dir.complete" ]; then
		echo "Reusing onesie ${version#v} from $dir"
		return
	fi

	local base="https://github.com/$repo/releases/download/$version"
	[ -z "$base_url" ] || base="$base_url"

	asset="onesie_${version#v}_${os}_${arch}.tar.gz"
	[ "$os" != "windows" ] || asset="onesie_${version#v}_${os}_${arch}.zip"

	local status
	if ! status="$(fetch "$tmp/checksums.txt" "$base/checksums.txt")"; then
		if [ -z "$base_url" ] && [ "$status" = "404" ]; then
			die "no onesie release named $version"
		fi
		die "could not download $base/checksums.txt"
	fi

	echo "Downloading $asset"
	fetch "$tmp/$asset" "$base/$asset" >/dev/null || die "could not download $base/$asset"

	verify_checksum
	verify_provenance

	mkdir -p "$tmp/unpack"
	extract "$tmp/$asset" "$tmp/unpack"
	smoke_test "$tmp/unpack"

	if ! { rm -rf "$dir" && mkdir -p "${dir%/*}" && mv "$tmp/unpack" "$dir"; }; then
		die "could not install onesie into $dir"
	fi
	if ! { [ -f "$dir/onesie" ] || [ -f "$dir/onesie.exe" ]; } || ! touch "$dir.complete"; then
		die "could not install onesie into $dir"
	fi
	echo "Installed onesie ${version#v} to $dir"
}

fetch() {
	curl -fsSL --retry 3 --proto '=https,file' --proto-redir '=https' -w '%{http_code}' -o "$1" --url "$2"
}

verify_checksum() {
	local want got
	want="$(awk -v name="$asset" '$2 == name { print $1 }' "$tmp/checksums.txt")"
	[ -n "$want" ] || die "checksums.txt has no line for $asset"

	if command -v sha256sum >/dev/null 2>&1; then
		got="$(sha256sum "$tmp/$asset" | awk '{ print $1 }')"
	else
		got="$(shasum -a 256 "$tmp/$asset" | awk '{ print $1 }')"
	fi

	[ "$got" = "$want" ] || die "the sha256 of $asset is $got, but checksums.txt says $want"
	echo "Verified the sha256 of $asset"
}

verify_provenance() {
	if [ "${INPUT_VERIFY_PROVENANCE:-true}" = "false" ]; then
		echo "Skipped the provenance check, since verify-provenance is false"
		return
	fi

	command -v gh >/dev/null 2>&1 ||
		die "gh is not installed, so provenance cannot be checked. Install it or set verify-provenance: false"

	gh attestation verify "$tmp/$asset" --repo "$repo" --signer-workflow "$signer_workflow" >/dev/null ||
		die "gh attestation verify found no provenance from onesie's release workflow for $asset"
	echo "Verified the provenance of $asset"
}

extract() {
	if [ "$os" = "windows" ]; then
		# Git's GNU tar cannot read zip and takes a drive letter for a remote host, so this uses the bsdtar Windows ships.
		"${SYSTEMROOT:-C:/Windows}/System32/tar.exe" -xf "$1" -C "$2" onesie.exe
	else
		tar -xzf "$1" -C "$2" onesie
	fi || die "could not unpack $asset"
}

smoke_test() {
	local binary="$1/onesie" reported
	[ -f "$binary" ] || binary="$1/onesie.exe"

	reported="$("$binary" --version)" || die "$binary --version failed"
	[ "${reported%%$'\n'*}" = "onesie ${version#v}" ] ||
		die "$binary --version does not report ${version#v}"
}

die() {
	local message="$*"
	message="${message//%/%25}"
	message="${message//$'\r'/%0D}"
	message="${message//$'\n'/%0A}"
	echo "::error::$message"
	exit 1
}

main "$@"
