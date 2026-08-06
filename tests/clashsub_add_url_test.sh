#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=../scripts/cmd/clashctl.sh
. "$repo_dir/scripts/cmd/clashctl.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

help_output=$(clashctl sub --help)
[[ "$help_output" == *"add '<url>'"* ]] ||
    fail "sub help does not tell users to quote subscription URLs"
[[ "$help_output" == *"clashsub add 'https://example.com/sub?token=xxx&app=auto'"* ]] ||
    fail "sub help is missing a quoted URL example"

id=
CLASH_CONFIG_TEMP=/tmp/clashsub-add-url-test.yaml
BIN_SUBCONVERTER_LOG=/tmp/clashsub-add-url-test.log

_get_url_by_id() {
    return 1
}
_download_config() {
    return 1
}
_valid_config() {
    return 1
}
_error_quit() {
    printf '%s\n' "$1" >&2
    exit 1
}

set +e
error_output=$(clashctl sub add 'https://example.com/sub?sid=123' 2>&1)
status=$?
set -e

[ "$status" -ne 0 ] || fail "an invalid subscription unexpectedly succeeded"
[[ "$error_output" == *"Shell 可能已在 & 处截断链接"* ]] ||
    fail "invalid subscription error does not explain shell truncation"
[[ "$error_output" == *"clashctl sub add 'https://example.com/sub?token=xxx&app=auto'"* ]] ||
    fail "invalid subscription error is missing the corrected command example"

echo "PASS: clashctl sub add URL quoting guidance"
