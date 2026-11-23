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

# 5. provider 型订阅（如模思）：节点只在 proxy-providers[*].payload 里（带 YAML 锚点、跨 provider 重复），
#    应从 payload 生成 Chain-Auto、把节点复制到顶层供 dialer-proxy 解析，入口改用 include-all-proxies；
#    「订阅 · 香港」这类真实节点不能被「订阅」误杀，「订阅到期」这类提示节点仍要排除；订阅自带自动组开 lazy
cp "$repo_dir/resources/mixin.yaml" "$CLASH_CONFIG_MIXIN"
cat >"$CLASH_CONFIG_BASE" <<'EOF'
proxies:
  - { name: "启智专属入口", type: ss, server: 9.9.9.9, port: 443, cipher: aes-128-gcm, password: x }
proxy-providers:
  "模思 · 节点选择":
    type: http
    url: https://example.com/sub?a
    path: ./providers/a.yaml
    health-check: { enable: true, url: https://www.gstatic.com/generate_204, interval: 60, lazy: false }
    payload:
      - &a1 { name: "订阅 · 香港", type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: x }
      - &a2 { name: "订阅 · 日本", type: ss, server: 2.2.2.2, port: 443, cipher: aes-128-gcm, password: x }
      - { name: "订阅到期：2099-01-01", type: ss, server: 3.3.3.3, port: 443, cipher: aes-128-gcm, password: x }
  "模思 · 日本":
    type: http
    url: https://example.com/sub?b
    path: ./providers/b.yaml
    health-check: { enable: true, url: https://www.gstatic.com/generate_204, interval: 60, lazy: false }
    payload:
      - *a2
proxy-groups:
  - name: "🚀 节点选择"
    type: select
    use:
      - "模思 · 节点选择"
    proxies:
      - DIRECT
  - name: "日本自动"
    type: url-test
    use:
      - "模思 · 日本"
    url: https://www.gstatic.com/generate_204
    interval: 60
    lazy: false
rules:
  - MATCH,🚀 节点选择
EOF

_merge_config

assert_eq "$("$yq_bin" '[.proxies[] | select(.name | test("^链式测速\|")) | .name] | join(",")' "$CLASH_CONFIG_CHAIN")" "链式测速|订阅 · 香港,链式测速|订阅 · 日本" "provider payload nodes should become chain candidates (deduped, info nodes excluded)"
assert_eq "$("$yq_bin" '.payload-inlined' "$CLASH_CONFIG_CHAIN")" "true" "all providers carry payload → payload-inlined"
assert_eq "$("$yq_bin" '[.proxies[] | select(.name == "订阅 · 日本")] | length' "$CLASH_CONFIG_RUNTIME")" "1" "payload node should be copied to top-level proxies exactly once"
assert_eq "$("$yq_bin" '.proxy-groups[] | select(.name == "Claude-家宽") | .proxies[0]' "$CLASH_CONFIG_RUNTIME")" "Chain-Auto" "provider sub: Claude-家宽 should default to Chain-Auto"
assert_eq "$("$yq_bin" '.proxy-groups[] | select(.name == "入口") | (has("include-all") | tostring) + "," + (.include-all-proxies | tostring)' "$CLASH_CONFIG_RUNTIME")" "false,true" "provider sub with inline payload: 入口 should use include-all-proxies"
assert_eq "$("$yq_bin" '.proxy-groups[] | select(.name == "日本自动") | .lazy' "$CLASH_CONFIG_RUNTIME")" "true" "subscription url-test groups should be forced lazy"
assert_eq "$("$yq_bin" '.proxy-groups[] | select(.name == "Airport-Auto") | has("lazy")' "$CLASH_CONFIG_RUNTIME")" "false" "mixin own groups must not be forced lazy"
assert_eq "$("$yq_bin" '[.proxy-providers[] | .health-check.lazy] | unique | join(",")' "$CLASH_CONFIG_RUNTIME")" "true" "provider health-check should be forced lazy"

# 6. 混合型订阅：有 provider 不带 payload 时保留 include-all，避免漏掉远程 provider 的节点
"$yq_bin" -i 'del(.proxy-providers["模思 · 日本"].payload)' "$CLASH_CONFIG_BASE"
_merge_config
assert_eq "$("$yq_bin" '.payload-inlined' "$CLASH_CONFIG_CHAIN")" "false" "remote provider without payload → not payload-inlined"
assert_eq "$("$yq_bin" '.proxy-groups[] | select(.name == "入口") | (.include-all | tostring) + "," + (has("include-all-proxies") | tostring)' "$CLASH_CONFIG_RUNTIME")" "true,false" "mixed sub: 入口 should keep include-all"

echo "PASS: chain_auto_test"
