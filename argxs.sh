
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Usage:
# sudo bash vless-argo-multi.sh \
#   UUID \
#   "10001,10002,10003" \
#   "a.example.com,b.example.net,c.example.org" \
#   TUNNEL_TOKEN \
#   "pathA,pathB,pathC" \
#   PAD_HEADER \
#   PAD_KEY

[ "$#" -eq 7 ] || {
  echo "Usage: $0 UUID PORTS DOMAINS TOKEN PATHS PAD_HEADER PAD_KEY" >&2
  exit 1
}

UUID="$1"
PORTS="$2"
DOMAINS="$3"
ARGO_AUTH="$4"
PATHS="$5"
PAD_HEADER="$6"
PAD_KEY="$7"

BASE="${HOME}/vless-argo"

[ "$(id -u)" -eq 0 ] || {
  echo "Please run as root." >&2
  exit 1
}

# ---------- Validate basic inputs ----------

[[ "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || {
  echo "Invalid UUID." >&2
  exit 1
}

[[ -n "$ARGO_AUTH" && "$ARGO_AUTH" != *$'\n'* && "$ARGO_AUTH" != *$'\r'* ]] || {
  echo "Invalid Tunnel token." >&2
  exit 1
}

[[ "$PAD_HEADER" =~ ^[A-Za-z0-9-]+$ ]] || {
  echo "Invalid padding header." >&2
  exit 1
}

[[ "$PAD_KEY" =~ ^[A-Za-z0-9_]+$ ]] || {
  echo "Invalid padding key." >&2
  exit 1
}

[[ -n "$PORTS" && -n "$DOMAINS" && -n "$PATHS" ]] || exit 1

IFS=',' read -r -a PORT_ARR <<< "$PORTS"
IFS=',' read -r -a DOMAIN_ARR <<< "$DOMAINS"
IFS=',' read -r -a PATH_ARR <<< "$PATHS"

N="${#PORT_ARR[@]}"

[ "$N" -ge 2 ] &&
[ "${#DOMAIN_ARR[@]}" -eq "$N" ] &&
[ "${#PATH_ARR[@]}" -eq "$N" ] || {
  echo "Ports, domains and paths must have the same count (at least 2)." >&2
  exit 1
}

# Validate ports, hostnames and paths.
declare -A SEEN_PORTS=()
declare -A SEEN_DOMAINS=()
declare -A SEEN_PATHS=()

for ((i=0; i<N; i++)); do
  PORT="${PORT_ARR[$i]}"
  DOMAIN="${DOMAIN_ARR[$i],,}"
  PATH="${PATH_ARR[$i]#/}"

  [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || {
    echo "Invalid port: $PORT" >&2
    exit 1
  }

  (( 10#$PORT >= 1 && 10#$PORT <= 65535 )) || {
    echo "Port out of range: $PORT" >&2
    exit 1
  }

  PORT="$((10#$PORT))"

  # Validate DNS labels, including different root domains.
  [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || {
    echo "Invalid hostname: $DOMAIN" >&2
    exit 1
  }

  [[ ${#DOMAIN} -le 253 && "$DOMAIN" == *.* ]] || {
    echo "Invalid hostname: $DOMAIN" >&2
    exit 1
  }

  IFS='.' read -r -a LABELS <<< "$DOMAIN"
  for LABEL in "${LABELS[@]}"; do
    [[ "$LABEL" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] &&
    [ "${#LABEL}" -le 63 ] || {
      echo "Invalid DNS label in hostname: $DOMAIN" >&2
      exit 1
    }
  done

  [[ "$PATH" =~ ^[A-Za-z0-9_-]+$ ]] || {
    echo "Invalid XHTTP path: $PATH" >&2
    exit 1
  }

  [[ -z "${SEEN_PORTS[$PORT]+x}" ]] || {
    echo "Duplicate port: $PORT" >&2
    exit 1
  }

  [[ -z "${SEEN_DOMAINS[$DOMAIN]+x}" ]] || {
    echo "Duplicate hostname: $DOMAIN" >&2
    exit 1
  }

  [[ -z "${SEEN_PATHS[$PATH]+x}" ]] || {
    echo "Duplicate path: $PATH" >&2
    exit 1
  }

  SEEN_PORTS[$PORT]=1
  SEEN_DOMAINS[$DOMAIN]=1
  SEEN_PATHS[$PATH]=1

  PORT_ARR[$i]="$PORT"
  DOMAIN_ARR[$i]="$DOMAIN"
  PATH_ARR[$i]="$PATH"
done

CPU="arm64"
XRAY_ARCH="arm64-v8a"

command -v curl >/dev/null 2>&1 || {
  echo "curl is required." >&2
  exit 1
}
command -v unzip >/dev/null 2>&1 || {
  echo "unzip is required." >&2
  exit 1
}

mkdir -p "$BASE"
chmod 700 "$BASE"

# ---------- Install Xray if missing ----------

if [ ! -x "$BASE/xray" ]; then
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR:-}"' EXIT

  URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"

  curl -fL --retry 3 -o "$TMP_DIR/xray.zip" "$URL"
  unzip -o -q "$TMP_DIR/xray.zip" xray -d "$BASE"
  chmod 700 "$BASE/xray"

  rm -rf "$TMP_DIR"
  trap - EXIT
fi

# ---------- Install cloudflared if missing ----------

if [ ! -x "$BASE/cloudflared" ]; then
  URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CPU}"
  TMP_FILE="$(mktemp)"

  curl -fL --retry 3 -o "$TMP_FILE" "$URL"
  install -m 700 "$TMP_FILE" "$BASE/cloudflared"
  rm -f "$TMP_FILE"
fi

# ---------- Generate multiple Xray inbounds ----------

TMP_CONFIG="$(mktemp "$BASE/xray.json.XXXXXX")"
trap 'rm -f "${TMP_CONFIG:-}"' EXIT

printf '{"log":{"loglevel":"warning"},"inbounds":[' > "$TMP_CONFIG"

for ((i=0; i<N; i++)); do
  PORT="${PORT_ARR[$i]}"
  PATH="${PATH_ARR[$i]}"

  (( i > 0 )) && printf ',' >> "$TMP_CONFIG"

  cat >> "$TMP_CONFIG" <<JSON
{
  "listen": "127.0.0.1",
  "port": ${PORT},
  "protocol": "vless",
  "settings": {
    "clients": [
      {
        "id": "${UUID}"
      }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "none",
    "xhttpSettings": {
      "path": "/${PATH}",
      "mode": "packet-up",
      "xPaddingObfsMode": true,
      "xPaddingMethod": "tokenish",
      "xPaddingPlacement": "queryInHeader",
      "xPaddingHeader": "${PAD_HEADER}",
      "xPaddingKey": "${PAD_KEY}"
    }
  }
}
JSON
done

printf '],"outbounds":[{"protocol":"freedom"}]}' >> "$TMP_CONFIG"

chmod 600 "$TMP_CONFIG"

# Validate configuration before replacing the current one.
"$BASE/xray" run -test -c "$TMP_CONFIG"

mv -f "$TMP_CONFIG" "$BASE/xray.json"
trap - EXIT
chmod 600 "$BASE/xray.json"

# ---------- Save Tunnel token ----------

printf 'TUNNEL_TOKEN=%s\n' "$ARGO_AUTH" > "$BASE/cloudflared.env"
chmod 600 "$BASE/cloudflared.env"

# ---------- Configure services ----------

if command -v systemctl >/dev/null 2>&1 &&
   [ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" = "systemd" ]; then

  cat > /etc/systemd/system/vless-argo-xray.service <<UNIT
[Unit]
Description=VLESS XHTTP Multi-Inbound Xray
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=${BASE}/xray run -c ${BASE}/xray.json
Restart=always
RestartSec=3
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT

  cat > /etc/systemd/system/vless-argo.service <<UNIT
[Unit]
Description=Cloudflare Tunnel for VLESS XHTTP
Wants=network-online.target
After=network-online.target vless-argo-xray.service
Requires=vless-argo-xray.service

[Service]
Type=simple
EnvironmentFile=${BASE}/cloudflared.env
ExecStart=${BASE}/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run
Restart=always
RestartSec=3
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT

  chmod 644 \
    /etc/systemd/system/vless-argo-xray.service \
    /etc/systemd/system/vless-argo.service

  systemctl daemon-reload
  systemctl enable vless-argo-xray.service vless-argo.service

  systemctl restart vless-argo-xray.service
  systemctl restart vless-argo.service

  sleep 2

  systemctl --no-pager --full status vless-argo-xray.service || true
  systemctl --no-pager --full status vless-argo.service || true

else
  echo "This script's managed-service installation requires systemd." >&2
  echo "Install on a systemd-based VPS to avoid unmanaged background processes." >&2
  exit 1
fi

# ---------- Generate client links ----------

EXTRA='%7B%22xPaddingObfsMode%22%3Atrue%2C%22xPaddingMethod%22%3A%22tokenish%22%2C%22xPaddingPlacement%22%3A%22queryInHeader%22%2C%22xPaddingHeader%22%3A%22'"${PAD_HEADER}"'%22%2C%22xPaddingKey%22%3A%22'"${PAD_KEY}"'%22%7D'

echo
echo "===== VLESS XHTTP client links ====="
echo "NOTE: Configure each hostname in Cloudflare Zero Trust separately."
echo "NOTE: Links do not create Cloudflare routes automatically."
echo

for ((i=0; i<N; i++)); do
  DOMAIN="${DOMAIN_ARR[$i]}"
  PATH="${PATH_ARR[$i]}"

  printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h2&type=xhttp&host=%s&path=/%s&mode=packet-up&extra=%s#vless-xhttp-%d\n' \
    "$UUID" "$DOMAIN" "$DOMAIN" "$DOMAIN" "$PATH" "$EXTRA" "$((i+1))"
done

echo
echo "===== Next steps ====="
echo "1. Add each hostname to the existing Tunnel in Cloudflare Zero Trust."
echo "2. Map each hostname to http://localhost:<corresponding-port>."
echo "3. Test every client profile for upload, download and reconnect."
echo
echo "Configuration: $BASE/xray.json"
echo "Token file:    $BASE/cloudflared.env"
echo "Xray logs:     journalctl -u vless-argo-xray -f"
echo "Tunnel logs:   journalctl -u vless-argo -f"
