#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
yq_bin=${YQ_BIN:-/root/clashctl/bin/yq}
mihomo_bin=${MIHOMO_BIN:-/root/clashctl/bin/mihomo}

[ -x "$yq_bin" ] || {
    echo "yq not found: $yq_bin" >&2
    exit 1
}

test_dir=$(mktemp -d /tmp/chain-auto-test.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

# shellcheck source=../scripts/cmd/clashctl.sh
. "$repo_dir/scripts/cmd/clashctl.sh"

BIN_YQ="$yq_bin"
CLASH_CONFIG_BASE="$test_dir/config.yaml"
CLASH_CONFIG_MIXIN="$test_dir/mixin.yaml"
CLASH_CONFIG_CHAIN="$test_dir/chain.yaml"
CLASH_CONFIG_RUNTIME="$test_dir/runtime.yaml"
CLASH_CONFIG_TEMP="$test_dir/temp.yaml"

_error_quit() {
    echo "ERROR: $*" >&2
    exit 1
}

_valid_config() {
    local cfg="$1"
    [ -s "$cfg" ] || return 1
    if [ -x "$mihomo_bin" ] && [ -f /root/clashctl/resources/ASN.mmdb ]; then
        cp -n /root/clashctl/resources/Country.mmdb /root/clashctl/resources/ASN.mmdb /root/clashctl/resources/geosite.dat "$test_dir/" 2>/dev/null || true
        "$mihomo_bin" -d "$test_dir" -t -f "$cfg"
    fi
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local got="$1" expected="$2" msg="$3"
    [ "$got" = "$expected" ] || fail "$msg (got='$got', expected='$expected')"
}

# 1. 空订阅：不生成空的 Chain-Auto 组，不注入悬空组名，mihomo -t 通过
cp "$repo_dir/resources/mixin.yaml" "$CLASH_CONFIG_MIXIN"
cat >"$CLASH_CONFIG_BASE" <<'EOF'
proxies: []
proxy-groups:
  - name: "节点选择"
    type: select
    proxies:
      - DIRECT
rules:
  - MATCH,节点选择
EOF

_merge_config

assert_eq "$("$yq_bin" '.proxies | length' "$CLASH_CONFIG_CHAIN")" "0" "empty sub should have 0 chain proxies"
assert_eq "$("$yq_bin" '.proxy-groups | length' "$CLASH_CONFIG_CHAIN")" "0" "empty sub should have 0 chain groups"
assert_eq "$("$yq_bin" '.proxy-groups[] | select(.name == "Claude-家宽") | .proxies[0]' "$CLASH_CONFIG_RUNTIME")" "家宽-01-链式代理" "empty sub Claude-家宽 should default to manual home exit"
assert_eq "$("$yq_bin" '.proxy-groups[] | select(.name == "节点选择") | .proxies | any_c(. == "Chain-Auto")' "$CLASH_CONFIG_RUNTIME")" "false" "empty sub must not inject missing Chain-Auto"

# 2. 单家宽 + 节点过滤：生成 Chain-Auto，置顶 Claude-家宽 且注入订阅 select 组，不污染 入口
cat >"$CLASH_CONFIG_BASE" <<'EOF'
proxies:
  - { name: "HK-01", type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: x }
  - { name: "US-01", type: ss, server: 2.2.2.2, port: 443, cipher: aes-128-gcm, password: x }
  - { name: "剩余流量 100GB", type: ss, server: 3.3.3.3, port: 443, cipher: aes-128-gcm, password: x }
proxy-groups:
  - name: "节点选择"
    type: select
    proxies:
      - HK-01
      - US-01
  - name: "自动选择"
    type: url-test
    proxies:
      - HK-01
      - US-01
rules:
  - MATCH,节点选择
EOF

_merge_config

assert_eq "$("$yq_bin" '.proxies | length' "$CLASH_CONFIG_CHAIN")" "2" "single exit should filter subscription nodes"
assert_eq "$("$yq_bin" '.proxy-groups[0].name' "$CLASH_CONFIG_CHAIN")" "Chain-Auto" "single exit should keep Chain-Auto name"
assert_eq "$("$yq_bin" '.proxy-groups[0].lazy' "$CLASH_CONFIG_CHAIN")" "true" "Chain-Auto should enable lazy by default"
assert_eq "$("$yq_bin" '.proxy-groups[0].proxies | length' "$CLASH_CONFIG_CHAIN")" "2" "Chain-Auto should list explicit deduplicated chain proxies"
assert_eq "$("$yq_bin" '.proxy-groups[] | select(.name == "Claude-家宽") | .proxies[0]' "$CLASH_CONFIG_RUNTIME")" "Chain-Auto" "Claude-家宽 should default to Chain-Auto"
assert_eq "$("$yq_bin" '.proxy-groups[] | select(.name == "入口") | .proxies | any_c(. == "Chain-Auto")' "$CLASH_CONFIG_RUNTIME")" "false" "入口 must never contain Chain-Auto"
assert_eq "$("$yq_bin" '.proxy-groups[] | select(.name == "节点选择") | .proxies | any_c(. == "Chain-Auto")' "$CLASH_CONFIG_RUNTIME")" "true" "inject-all should include Chain-Auto in select groups"
assert_eq "$("$yq_bin" '.proxy-groups[] | select(.name == "自动选择") | .proxies | any_c(. == "Chain-Auto")' "$CLASH_CONFIG_RUNTIME")" "false" "url-test group must not be injected"

# 3. 多家宽 + 自定义 dialer-proxy 出口：按 入口 出口拆分为 <家宽名>-Auto，跳过自定义 dialer-proxy
cat >"$CLASH_CONFIG_MIXIN" <<'EOF'
proxies:
  prefix:
    - name: "加州-链式01"
      type: socks5
      server: "127.0.0.1"
      port: 1080
      udp: true
      dialer-proxy: "入口"
    - name: "日本-链式01"
      type: socks5
      server: "127.0.0.2"
      port: 1080
      udp: true
      dialer-proxy: "入口"
    - name: "专线出口"
      type: socks5
      server: "127.0.0.3"
      port: 1080
      udp: true
      dialer-proxy: "HK-01"
proxy-groups:
  prefix:
    - name: "Airport-Auto"
      type: url-test
      include-all: true
      exclude-filter: "(?i)链式|家宽|流量"
      url: http://www.gstatic.com/generate_204
      interval: 300
      tolerance: 50
    - name: "入口"
      type: select
      proxies:
        - "Airport-Auto"
      include-all: true
      exclude-filter: "(?i)链式|家宽|流量"
    - name: "Claude-家宽"
      type: select
      proxies:
        - "加州-链式01"
        - "日本-链式01"
        - "专线出口"
  inject-all:
    - "加州-链式01"
    - "日本-链式01"
EOF

_merge_config

assert_eq "$("$yq_bin" '.proxies | length' "$CLASH_CONFIG_CHAIN")" "4" "2 entry exits x 2 nodes should generate 4 chain proxies"
assert_eq "$("$yq_bin" '[.proxy-groups[].name] | join(",")' "$CLASH_CONFIG_CHAIN")" "加州-链式01-Auto,日本-链式01-Auto" "multi exit should generate per-exit -Auto groups and skip custom dialer-proxy"
assert_eq "$("$yq_bin" '.proxy-groups[] | select(.name == "Claude-家宽") | .proxies[0]' "$CLASH_CONFIG_RUNTIME")" "加州-链式01-Auto" "Claude-家宽 first default should be 加州-链式01-Auto"
assert_eq "$("$yq_bin" '.proxy-groups[] | select(.name == "Claude-家宽") | .proxies[1]' "$CLASH_CONFIG_RUNTIME")" "日本-链式01-Auto" "Claude-家宽 second entry should be 日本-链式01-Auto"
assert_eq "$("$yq_bin" '.proxy-groups[] | select(.name == "入口") | .proxies | any_c(. == "加州-链式01-Auto" or . == "日本-链式01-Auto")' "$CLASH_CONFIG_RUNTIME")" "false" "入口 must not contain per-exit -Auto groups"
assert_eq "$("$yq_bin" '.proxy-groups[] | select(.name == "节点选择") | .proxies | any_c(. == "日本-链式01-Auto")' "$CLASH_CONFIG_RUNTIME")" "true" "inject-all should include per-exit -Auto groups"

# 4. 未配置 inject-all 时：订阅 select 组不被强行注入，Claude-家宽 仍正常置顶 Chain-Auto
cp "$repo_dir/resources/mixin.yaml" "$CLASH_CONFIG_MIXIN"
"$yq_bin" -i 'del(.proxy-groups.inject-all)' "$CLASH_CONFIG_MIXIN"
_merge_config
assert_eq "$("$yq_bin" '.proxy-groups[] | select(.name == "节点选择") | .proxies | any_c(. == "Chain-Auto")' "$CLASH_CONFIG_RUNTIME")" "false" "without inject-all, select group must not be modified"
assert_eq "$("$yq_bin" '.proxy-groups[] | select(.name == "Claude-家宽") | .proxies[0]' "$CLASH_CONFIG_RUNTIME")" "Chain-Auto" "without inject-all, Claude-家宽 should still default to Chain-Auto"

echo "PASS: chain_auto_test"
