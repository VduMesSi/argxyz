#!/bin/bash
set -e
umask 077

[ "$#" -eq 9 ] || exit 1
[ "$(id -u)" -eq 0 ] || exit 1

BASE="${HOME}/vless-argo"
ARGO_AUTH="$1"
UUID="$2"
RAND_PATH="${3#/}"
shift 3

[ -n "$ARGO_AUTH" ] && [ -n "$UUID" ] && [ -n "$RAND_PATH" ] || exit 1
case "$ARGO_AUTH" in *[$'\n\r ']*) exit 1 ;; esac
case "$UUID" in *[!0-9A-Fa-f-]*) exit 1 ;; esac
case "$RAND_PATH" in *[!A-Za-z0-9_-]*) exit 1 ;; esac

N=3
T_DOMAIN=(); T_PORT=()
for ((i=0; i<N; i++)); do
  D="$1"; P="$2"
  shift 2
  [ -n "$D" ] && [ -n "$P" ] || exit 1
  case "$D" in *[!A-Za-z0-9.-]*) exit 1 ;; esac
  case "$P" in *[!0-9]*) exit 1 ;; esac
  [ "$P" -ge 1 ] && [ "$P" -le 65535 ] || exit 1
  for ((j=0; j<i; j++)); do
    [ "${T_DOMAIN[$j]}" != "$D" ] || exit 1
    [ "${T_PORT[$j]}" != "$P" ] || exit 1
  done
  T_DOMAIN[$i]="$D"; T_PORT[$i]="$P"
done

case "$(uname -m)" in
  x86_64|amd64) CPU=amd64; XRAY_ARCH="64" ;;
  aarch64|arm64) CPU=arm64; XRAY_ARCH="arm64-v8a" ;;
  *) exit 1 ;;
esac

command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || exit 1
command -v unzip >/dev/null 2>&1 || exit 1
mkdir -p "$BASE"
chmod 700 "$BASE"

if [ ! -x "$BASE/xray" ]; then
  URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"
  TMP_ZIP="$(mktemp)"
  curl -fsSL --retry 3 -o "$TMP_ZIP" "$URL" 2>/dev/null || wget -qO "$TMP_ZIP" "$URL"
  unzip -o -q "$TMP_ZIP" xray -d "$BASE"
  rm -f "$TMP_ZIP"
  chmod 700 "$BASE/xray"
fi

if [ ! -x "$BASE/cloudflared" ]; then
  URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CPU}"
  curl -fsSL --retry 3 -o "$BASE/cloudflared" "$URL" 2>/dev/null || wget -qO "$BASE/cloudflared" "$URL"
  chmod 700 "$BASE/cloudflared"
fi

# ---------- xray.json：3 个 xhttp inbound（精简配置）----------
INBOUNDS=""
for ((k=0; k<N; k++)); do
  [ -z "$INBOUNDS" ] || INBOUNDS="${INBOUNDS},"
  INBOUNDS="${INBOUNDS}
    {
      \"tag\": \"in-$((k+1))\",
      \"listen\": \"127.0.0.1\",
      \"port\": ${T_PORT[$k]},
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [ { \"id\": \"${UUID}\" } ],
        \"decryption\": \"none\"
      },
      \"streamSettings\": {
        \"network\": \"xhttp\",
        \"security\": \"none\",
        \"xhttpSettings\": {
          \"path\": \"/${RAND_PATH}\",
          \"mode\": \"packet-up\"
        }
      }
    }"
done

cat > "$BASE/xray.json" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [${INBOUNDS}
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" }
    }
  ]
}
JSON
chmod 600 "$BASE/xray.json"

# ---------- token ----------
rm -f "$BASE"/cloudflared-*.env
printf 'TUNNEL_TOKEN=%s\n' "$ARGO_AUTH" > "$BASE/cloudflared.env"
chmod 600 "$BASE/cloudflared.env"

if command -v systemctl >/dev/null 2>&1 && [ "$(ps -p 1 -o comm= 2>/dev/null)" = systemd ]; then
  for f in /etc/systemd/system/vless-argo-cf*.service; do
    [ -e "$f" ] || continue
    systemctl disable --now "$(basename "$f")" >/dev/null 2>&1 || true
    rm -f "$f"
  done

  cat > /etc/systemd/system/vless-argo-xray.service <<UNIT
[Unit]
After=network.target

[Service]
Type=simple
ExecStart=${BASE}/xray run -c ${BASE}/xray.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

  cat > /etc/systemd/system/vless-argo.service <<UNIT
[Unit]
After=network.target vless-argo-xray.service
Requires=vless-argo-xray.service

[Service]
Type=simple
EnvironmentFile=${BASE}/cloudflared.env
ExecStart=${BASE}/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
  chmod 644 /etc/systemd/system/vless-argo-xray.service /etc/systemd/system/vless-argo.service

  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable vless-argo-xray.service vless-argo.service >/dev/null 2>&1
  systemctl restart vless-argo-xray.service >/dev/null 2>&1
  systemctl restart vless-argo.service >/dev/null 2>&1
else
  pkill -f "${BASE}/xray run -c ${BASE}/xray.json" 2>/dev/null || true
  pkill -f "${BASE}/cloudflared tunnel" 2>/dev/null || true
  nohup "$BASE/xray" run -c "$BASE/xray.json" >/dev/null 2>&1 &
  TUNNEL_TOKEN="$ARGO_AUTH" nohup "$BASE/cloudflared" tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run >/dev/null 2>&1 &
fi

for ((k=0; k<N; k++)); do
  printf '\n# route %s  domain=%s  port=%s\n' "$((k+1))" "${T_DOMAIN[$k]}" "${T_PORT[$k]}"
  printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h2&type=xhttp&host=%s&path=%%2F%s&mode=packet-up#vless-xhttp-argo-%s\n' \
    "$UUID" "${T_DOMAIN[$k]}" "${T_DOMAIN[$k]}" "${T_DOMAIN[$k]}" "$RAND_PATH" "$((k+1))"
done

printf '\npath: /%s\nmode: packet-up\n' "$RAND_PATH"
