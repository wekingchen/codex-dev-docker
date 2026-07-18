# 由personal-remote entrypoint在/run中生成实际代理环境。
# shellcheck disable=SC1091
if [ -r /run/codex-proxy/env.sh ]; then
  . /run/codex-proxy/env.sh
fi
