# shellcheck shell=bash
# Holds the annotation helpers that install.sh and run.sh share. Source it, do not run it.

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
