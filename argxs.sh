
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# ============================================================
# VLESS + XHTTP packet-up + Cloudflare Tunnel Token
#
# Usage:
# bash install-multi-domain.sh \
#   UUID PORTS DOMAINS TUNNEL_TOKEN PATHS PAD_HEADER PAD_KEY
#
# Example:
# bash install-multi-domain.sh \
#   7f3c2b1a-6d84-4e92-a531-9c7f28b6d415 \
#   10001,10002 \
#   a.example.com,b.example.net \
#   'YOUR_CLOUDFLARE_TUNNEL_TOKEN' \
#   /alpha-path,/beta-path \
#   X-Padding csrf_token
#
# PORTS, DOMAINS and PATHS must have the same number of items.
# ============================================================

# ---------- CPU architecture ----------
# Default: x86_64 / amd64 VPS.
# For ARM64 VPS, change these to:
# CPU="arm64"
# XRAY_ARCH="arm64-v8a"

CPU="amd64"
XRAY_ARCH="64"

# ---------- Installation directory ----------
BASE="/opt/vless-argo"
XRAY_BIN="${BASE}/xray"
XRAY_CONFIG="${BASE}/config.json"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
TOKEN_FILE="${BASE}/cloudflared.env"

XRAY_SERVICE="vless-argo-xray"
CF_SERVICE="vless-argo"

# ---------- Basic checks ----------
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run this script as root." >&2
    exit 1
fi

if [[ "$#" -ne 7 ]]; then
    echo "Usage:"
    echo "bash $0 UUID PORTS DOMAINS TUNNEL_TOKEN PATHS PAD_HEADER PAD_KEY"
    exit 1
fi

UUID="$1"
PORTS_RAW="$2"
DOMAINS_RAW="$3"
TUNNEL_TOKEN="$4"
PATHS_RAW="$5"
PAD_HEADER="$6"
PAD_KEY="$7"

if [[ ! "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "ERROR: Invalid UUID." >&2
    exit 1
fi

if [[ -z "$TUNNEL_TOKEN" || "$TUNNEL_TOKEN" == *$'\n'* ]]; then
    echo "ERROR: Invalid Cloudflare Tunnel Token." >&2
    exit 1
fi

# Restrict values inserted into JSON to simple safe characters.
if [[ ! "$PAD_HEADER" =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "ERROR: PAD_HEADER may contain only letters, numbers and hyphens." >&2
    exit 1
fi

if [[ ! "$PAD_KEY" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ERROR: PAD_KEY may contain only letters, numbers, underscores and hyphens." >&2
    exit 1
fi

IFS=',' read -r -a PORTS <<< "$PORTS_RAW"
IFS=',' read -r -a DOMAINS <<< "$DOMAINS_RAW"
IFS=',' read -r -a PATHS <<< "$PATHS_RAW"

COUNT="${#PORTS[@]}"

if [[ "$COUNT" -lt 1 ||
      "${#DOMAINS[@]}" -ne "$COUNT" ||
      "${#PATHS[@]}" -ne "$COUNT" ]]; then
    echo "ERROR: PORTS, DOMAINS and PATHS must contain the same number of items." >&2
    exit 1
fi

declare -A SEEN_PORTS=()
declare -A SEEN_DOMAINS=()

for i in "${!PORTS[@]}"; do
    port="${PORTS[$i]}"
    domain="${DOMAINS[$i]}"
    path="${PATHS[$i]}"

    if [[ ! "$port" =~ ^[0-9]+$ ]] ||
       (( port < 1 || port > 65535 )); then
        echo "ERROR: Invalid port: $port" >&2
        exit 1
    fi

    if [[ -n "${SEEN_PORTS[$port]+x}" ]]; then
        echo "ERROR: Duplicate port: $port" >&2
        exit 1
    fi
    SEEN_PORTS["$port"]=1

    domain="${domain,,}"
    DOMAINS[$i]="$domain"

    if [[ ! "$domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] ||
       [[ "$domain" == *..* ]]; then
        echo "ERROR: Invalid domain: $domain" >&2
        exit 1
    fi

    if [[ -n "${SEEN_DOMAINS[$domain]+x}" ]]; then
        echo "ERROR: Duplicate domain: $domain" >&2
        exit 1
    fi
    SEEN_DOMAINS["$domain"]=1

    if [[ ! "$path" =~ ^/[A-Za-z0-9/_-]+$ ]]; then
        echo "ERROR: Invalid XHTTP path: $path" >&2
        echo "Use a path beginning with / and containing letters, numbers, /, _ or -." >&2
        exit 1
    fi
done

# ---------- Download helper ----------
# curl is preferred; wget is supported as a fallback.
if ! command -v curl >/dev/null 2>&1 &&
   ! command -v wget >/dev/null 2>&1; then
    echo "ERROR: curl or wget is required." >&2
    echo "Debian/Ubuntu: apt-get update && apt-get install -y curl unzip" >&2
    exit 1
fi

if ! command -v unzip >/dev/null 2>&1; then
    echo "ERROR: unzip is required." >&2
    echo "Debian/Ubuntu: apt-get update && apt-get install -y unzip" >&2
    exit 1
fi

download_file() {
    local url="$1"
    local output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fLsS --retry 3 --connect-timeout 15 \
            "$url" -o "$output"
    else
        wget -q --tries=3 --timeout=15 \
            "$url" -O "$output"
    fi
}

# ---------- Check operating environment ----------
if ! command -v systemctl >/dev/null 2>&1; then
    echo "ERROR: systemd/systemctl is required." >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required to validate the JSON config." >&2
    echo "Debian/Ubuntu: apt-get install -y python3" >&2
    exit 1
fi

mkdir -p "$BASE"
chmod 700 "$BASE"

TMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# ---------- Download Xray ----------
echo "[1/7] Downloading Xray-core..."

XRAY_ZIP="${TMP_DIR}/xray.zip"
download_file \
    "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip" \
    "$XRAY_ZIP"

unzip -oq "$XRAY_ZIP" xray -d "$TMP_DIR"
install -m 755 "${TMP_DIR}/xray" "$XRAY_BIN"

# ---------- Download cloudflared ----------
echo "[2/7] Downloading cloudflared..."

CF_ARCH="$CPU"
download_file \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
    "${TMP_DIR}/cloudflared"

install -m 755 "${TMP_DIR}/cloudflared" "$CLOUDFLARED_BIN"

# ---------- Generate Xray config ----------
echo "[3/7] Generating Xray configuration..."

cat > "$XRAY_CONFIG" <<'JSON_HEAD'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
JSON_HEAD

for i in "${!PORTS[@]}"; do
    if (( i > 0 )); then
        printf ',\n' >> "$XRAY_CONFIG"
    fi

    cat >> "$XRAY_CONFIG" <<JSON_INBOUND
    {
      "listen": "127.0.0.1",
      "port": ${PORTS[$i]},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "email": "domain-${i}"
          }
        ],
        "decryption": "none",
        "encryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "${PATHS[$i]}",
          "mode": "packet-up",
          "xPaddingBytes": "100-1000",
          "xPaddingObfsMode": true,
          "xPaddingHeader": "${PAD_HEADER}",
          "xPaddingKey": "${PAD_KEY}"
        }
      },
      "sniffing": {
        "enabled": false
      }
    }
JSON_INBOUND
done

cat >> "$XRAY_CONFIG" <<'JSON_TAIL'
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
JSON_TAIL

chmod 600 "$XRAY_CONFIG"

# ---------- Validate config ----------
echo "[4/7] Validating Xray configuration..."

python3 -m json.tool "$XRAY_CONFIG" >/dev/null

"$XRAY_BIN" run -test -config "$XRAY_CONFIG"

# ---------- Configure Cloudflare Token ----------
echo "[5/7] Configuring Cloudflare Tunnel..."

printf 'TUNNEL_TOKEN=%s\n' "$TUNNEL_TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

# A wrapper avoids systemd variable-expansion problems.
cat > "${BASE}/run-cloudflared.sh" <<'CF_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/local/bin/cloudflared tunnel \
    --no-autoupdate \
    --protocol http2 \
    run \
    --token "$TUNNEL_TOKEN"
CF_WRAPPER
chmod 700 "${BASE}/run-cloudflared.sh"

# ---------- Create systemd services ----------
echo "[6/7] Creating systemd services..."

cat > "/etc/systemd/system/${XRAY_SERVICE}.service" <<XRAY_UNIT
[Unit]
Description=VLESS XHTTP packet-up multi-domain service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
XRAY_UNIT

cat > "/etc/systemd/system/${CF_SERVICE}.service" <<CF_UNIT
[Unit]
Description=Cloudflare Tunnel for VLESS XHTTP
After=network-online.target ${XRAY_SERVICE}.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${TOKEN_FILE}
ExecStart=${BASE}/run-cloudflared.sh
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
CF_UNIT

systemctl daemon-reload
systemctl enable "$XRAY_SERVICE" "$CF_SERVICE"
systemctl restart "$XRAY_SERVICE"
systemctl restart "$CF_SERVICE"

sleep 2

if ! systemctl is-active --quiet "$XRAY_SERVICE"; then
    echo "ERROR: Xray service failed to start." >&2
    systemctl --no-pager --full status "$XRAY_SERVICE" || true
    journalctl -u "$XRAY_SERVICE" -n 50 --no-pager || true
    exit 1
fi

if ! systemctl is-active --quiet "$CF_SERVICE"; then
    echo "WARNING: cloudflared service is not active yet." >&2
    systemctl --no-pager --full status "$CF_SERVICE" || true
    journalctl -u "$CF_SERVICE" -n 50 --no-pager || true
fi

# ---------- Output connection links ----------
echo
echo "[7/7] Installation finished."
echo
echo "Xray service:       systemctl status ${XRAY_SERVICE}"
echo "Cloudflare service: systemctl status ${CF_SERVICE}"
echo "Xray config:        ${XRAY_CONFIG}"
echo
echo "IMPORTANT: Add each hostname in the Cloudflare Zero Trust Tunnel dashboard:"
echo "  hostname -> http://127.0.0.1:PORT"
echo

for i in "${!PORTS[@]}"; do
    domain="${DOMAINS[$i]}"
    path="${PATHS[$i]}"
    encoded_path="${path//\//%2F}"

    printf 'Domain: %s\n' "$domain"
    printf 'Origin: http://127.0.0.1:%s\n' "${PORTS[$i]}"
    printf 'Path:   %s\n' "$path"
    printf 'VLESS:  vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&type=xhttp&host=%s&path=%s&mode=packet-up#%s\n\n' \
        "$UUID" "$domain" "$domain" "$domain" "$encoded_path" "$domain"
done

echo "Check logs with:"
echo "  journalctl -u ${XRAY_SERVICE} -n 100 --no-pager"
echo "  journalctl -u ${CF_SERVICE} -n 100 --no-pager"
