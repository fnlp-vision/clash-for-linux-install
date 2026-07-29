#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
yq_bin=${YQ_BIN:-/root/clashctl/bin/yq}

[ -x "$yq_bin" ] || {
    echo "yq not found: $yq_bin" >&2
    exit 1
}

test_dir=$(mktemp -d /tmp/clashsub-rename-test.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

meta_path="$test_dir/profiles.yaml"
log_path="$test_dir/profiles.log"
profile_one="$test_dir/1.yaml"
profile_two="$test_dir/2.yaml"

printf 'proxies: []\n' >"$profile_one"
printf 'proxies: []\n' >"$profile_two"
printf 'use: 1\nprofiles:\n  - id: 1\n    path: %s\n    url: https://example.com/main\n  - id: 2\n    name: 备用机场\n    path: %s\n    url: https://example.com/backup\n' \
    "$profile_one" "$profile_two" >"$meta_path"

# shellcheck source=../scripts/cmd/clashctl.sh
. "$repo_dir/scripts/cmd/clashctl.sh"

BIN_YQ="$yq_bin"
CLASH_PROFILES_META="$meta_path"
CLASH_PROFILES_LOG="$log_path"
CLASH_CONFIG_BASE="$test_dir/config.yaml"
CLASH_CONFIG_TEMP="$test_dir/temp.yaml"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

expect_failure() {
    local before
    before=$(sha256sum "$meta_path")
    if (
        _error_quit() {
            exit 1
        }
        clashsub "$@"
    ) >/dev/null 2>&1; then
        fail "expected failure: clashsub $*"
    fi
    [ "$before" = "$(sha256sum "$meta_path")" ] ||
        fail "failed command changed metadata: clashsub $*"
}

clashctl sub rename 1 '  公司 "主力" & 机场  ' >/dev/null

[ "$("$yq_bin" '.profiles[] | select(.id == 1) | .name' "$meta_path")" = '公司 "主力" & 机场' ] ||
    fail "special characters or surrounding whitespace were not handled"
[ "$("$yq_bin" '.use' "$meta_path")" = 1 ] ||
    fail "rename changed the active subscription"
[ "$("$yq_bin" '.profiles[] | select(.id == 1) | .path' "$meta_path")" = "$profile_one" ] ||
    fail "rename changed the profile path"
[ "$("$yq_bin" '.profiles[] | select(.id == 1) | .url' "$meta_path")" = https://example.com/main ] ||
    fail "rename changed the subscription URL"

list_output=$(clashsub ls)
[[ "$list_output" == *'name: 公司 "主力" & 机场'* ]] ||
    fail "renamed subscription is not visible in clashsub ls"

help_output=$(clashctl sub --help)
[[ "$help_output" == *'rename <id> <name>'* ]] ||
    fail "rename is missing from clashctl sub --help"

expect_failure rename 2 '公司 "主力" & 机场'
expect_failure rename 99 '不存在'
expect_failure rename abc '非法 id'
expect_failure rename 1 '   '

clashsub rename 1 '公司 "主力" & 机场' >/dev/null
[ "$(wc -l <"$log_path")" = 1 ] ||
    fail "renaming to the current name should not add a log entry"

grep -Fq '订阅已重命名：[1] 未命名 -> 公司 "主力" & 机场' "$log_path" ||
    fail "rename was not logged"

_download_config() {
    printf 'mixed-port: 7891\n' >"$1"
}
_valid_config() {
    return 0
}
_merge_config_restart() {
    return 0
}

clashsub update 1 >/dev/null
[ "$("$yq_bin" '.profiles[] | select(.id == 1) | .name' "$meta_path")" = '公司 "主力" & 机场' ] ||
    fail "updating a renamed subscription removed its name"
[ "$(cat "$CLASH_CONFIG_BASE")" = 'mixed-port: 7891' ] ||
    fail "updating the active renamed subscription did not activate it"

clashsub del 2 >/dev/null
[ ! -e "$profile_two" ] ||
    fail "deleting another named subscription did not remove its profile"
[ "$("$yq_bin" '.profiles | length' "$meta_path")" = 1 ] ||
    fail "deleting another named subscription changed the wrong metadata"
[ "$("$yq_bin" '.profiles[0].name' "$meta_path")" = '公司 "主力" & 机场' ] ||
    fail "deleting another subscription changed the renamed profile"

echo "PASS: clashctl sub rename"
