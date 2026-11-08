#!/usr/bin/env bash
# Checks the run mode inputs in action.yml. Without check, it then asks onesie one question and sets result, exit-code and answer.

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

main() {
	set -euo pipefail

	check_inputs
	[ "${1:-}" != "check" ] || return 0

	check_runner
	command -v onesie >/dev/null 2>&1 || die "onesie is not on PATH, so the install step did not finish"

	tmp="$(mktemp -d "$RUNNER_TEMP/setup-onesie.XXXXXX")"
	trap 'rm -rf "$tmp"' EXIT

	ask
	write_outputs
	apply_policy
}

check_inputs() {
	local file="${INPUT_FILE:-}" questions="${INPUT_QUESTIONS:-}" state="${INPUT_STATE:-}"
	on_fail="${INPUT_ON_FAIL:-error}"
	on_unsure="${INPUT_ON_UNSURE:-warn}"

	check_policy on-fail "$on_fail"
	check_policy on-unsure "$on_unsure"

	if [ -n "$file" ] && [ -n "$questions" ]; then
		die "file and questions are both set. Set one of them"
	fi

	if [ -n "$file$questions" ]; then
		[ -n "${state//[[:space:]]/}" ] || die "state is empty. Run mode needs the text to ask about in state"
		return 0
	fi

	[ -z "$state" ] || die "state is set without file or questions. Set one of them to ask about state"
	[ "$on_fail" = "error" ] || die "on-fail is set without file or questions. It applies in run mode only"
	[ "$on_unsure" = "warn" ] || die "on-unsure is set without file or questions. It applies in run mode only"
}

check_policy() {
	case "$2" in
	error | warn | continue) ;;
	*) die "$1 must be error, warn or continue, not $2" ;;
	esac
}

check_runner() {
	local name
	for name in RUNNER_TEMP GITHUB_OUTPUT; do
		[ -n "${!name:-}" ] || die "$name is not set, so run.sh is not running as a GitHub Actions step"
	done
}

ask() {
	local file="${INPUT_FILE:-}"
	if [ -n "${INPUT_QUESTIONS:-}" ]; then
		file="$tmp/questions.yaml"
		printf '%s\n' "$INPUT_QUESTIONS" >"$file"
	fi

	# Git Bash on Windows rewrites an argument that looks like a POSIX path, and onesie v0.15.0 drops --state-file, so the state reaches onesie on stdin from a file.
	printf '%s' "$INPUT_STATE" >"$tmp/state"

	status=0
	answer="$(onesie -f "$file" -o json --state - <"$tmp/state" 2>"$tmp/stderr")" || status=$?

	case "$status" in
	0) result="pass" ;;
	1) result="fail" ;;
	7) result="unsure" ;;
	*) result="no-answer" ;;
	esac
}

write_outputs() {
	local delimiter
	delimiter="ONESIE_$(random_hex)"
	[[ "$answer" != *"$delimiter"* ]] || die "onesie's answer holds the output delimiter, so it cannot be set as an output"

	{
		echo "result=$result"
		echo "exit-code=$status"
		echo "answer<<$delimiter"
		printf '%s\n' "$answer"
		echo "$delimiter"
	} >>"$GITHUB_OUTPUT"
}

apply_policy() {
	if [ "$result" = "no-answer" ]; then
		local reason
		reason="$(cat "$tmp/stderr")"
		die "onesie gave no answer, exit $status${reason:+$'\n'$reason}"
	fi

	print_stderr

	case "$result" in
	pass) echo "$answer" ;;
	fail) apply "$on_fail" "onesie answered fail, exit 1: $answer" ;;
	unsure) apply "$on_unsure" "onesie is unsure, exit 7: $answer" ;;
	esac
}

print_stderr() {
	[ -s "$tmp/stderr" ] || return 0

	local token
	token="$(random_hex)"
	echo "::stop-commands::$token"
	cat "$tmp/stderr"
	echo "::$token::"
}

apply() {
	case "$1" in
	error) die "$2" ;;
	warn) annotate warning "$2" ;;
	continue) echo "$2" ;;
	esac
}

random_hex() {
	od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
}

main "$@"
