#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "用法：validate-xray-config.sh <Xray配置文件>" >&2
  exit 2
fi

config_file="$1"

if [ ! -f "$config_file" ]; then
  echo "Xray配置验证器无法读取普通文件：$config_file" >&2
  exit 1
fi

if ! jq -e '
  type == "object" and
  (.log | type == "object") and
  .log.access == "none" and
  (.log.loglevel == "warning" or .log.loglevel == "error" or .log.loglevel == "none") and
  ((.log.dnsLog // false) != true) and
  (.inbounds | type == "array" and length > 0) and
  all(.inbounds[];
    type == "object" and
    (.listen == "127.0.0.1" or .listen == "::1")
  ) and
  ([.inbounds[] |
    select(.protocol == "http" and .listen == "127.0.0.1" and .port == 10809)
  ] | length == 1) and
  (.outbounds | type == "array" and length > 0) and
  all(.outbounds[]; type == "object" and (.protocol | type == "string" and length > 0)) and
  (.outbounds[0].protocol != "freedom" and .outbounds[0].protocol != "blackhole")
' "$config_file" >/dev/null; then
  echo "Xray配置不符合loopback HTTP inbound、关闭access log及远端代理默认出口的公共安全契约。" >&2
  exit 1
fi

freedom_count="$(jq '[.outbounds[] | select(.protocol == "freedom")] | length' "$config_file")"

case "$freedom_count" in
  0)
    printf '%s\n' all-proxy
    ;;
  1)
    if ! jq -e '
      (.outbounds | length == 3) and
      ([.outbounds[].tag] == ["proxy", "direct", "block"]) and
      ([.outbounds[].tag] | unique | length == 3) and
      (.outbounds[0].protocol as $proxy_protocol |
        ["vless", "vmess", "trojan", "shadowsocks", "socks"] | index($proxy_protocol) != null
      ) and
      (.outbounds[1] == {
        "tag": "direct",
        "protocol": "freedom",
        "settings": {
          "domainStrategy": "UseIP",
          "finalRules": [
            {"action": "block", "ip": ["geoip:private"]}
          ]
        }
      }) and
      (.outbounds[2] == {
        "tag": "block",
        "protocol": "blackhole",
        "settings": {}
      }) and
      ([.outbounds[0] | .. | objects |
        select(
          ((.proxySettings? | type) == "object" and .proxySettings.tag? == "direct") or
          (.dialerProxy? == "direct")
        )
      ] | length == 0) and
      (.routing | type == "object") and
      .routing.domainStrategy == "IPOnDemand" and
      ((.routing.balancers // []) | type == "array" and length == 0) and
      (.routing.rules == [
        {
          "type": "field",
          "ip": ["geoip:private"],
          "outboundTag": "block"
        },
        {
          "type": "field",
          "domain": ["geosite:cn"],
          "outboundTag": "direct"
        },
        {
          "type": "field",
          "ip": ["geoip:cn"],
          "outboundTag": "direct"
        }
      ])
    ' "$config_file" >/dev/null; then
      echo "含freedom的Xray配置必须严格使用proxy/direct/block顺序、私网优先阻断及仅限中国域名/IP直连的cn-direct安全契约。" >&2
      exit 1
    fi
    printf '%s\n' cn-direct
    ;;
  *)
    echo "Xray配置最多只能包含一个受限的freedom direct outbound。" >&2
    exit 1
    ;;
esac
