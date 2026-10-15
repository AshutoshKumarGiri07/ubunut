#!/usr/bin/env bash
set -e

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use: curl -sL <URL> | sudo bash)"
    exit 1
fi

# Always protect SSH (22) and RDP (3389), plus any extra ports passed as arguments
BASE_PORTS=(22 3389)
ALL_PORTS=("${BASE_PORTS[@]}" "$@")

# Deduplicate ports and format for nftables and bash arrays
UNIQUE_PORTS=($(printf "%s\n" "${ALL_PORTS[@]}" | awk '/^[0-9]+$/' | sort -nu))
NFT_PORTS=$(IFS=,; echo "${UNIQUE_PORTS[*]}" | sed 's/,/, /g')
ARRAY_PORTS="${UNIQUE_PORTS[*]}"

echo "==> [1/5] Installing prerequisites and official Cloudflare WARP repository..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl gpg nftables iproute2 lsb-release ca-certificates

if ! command -v warp-cli >/dev/null 2>&1; then
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main" > /etc/apt/sources.list.d/cloudflare-client.list
    apt-get update -y
    apt-get install -y cloudflare-warp
else
    echo "    cloudflare-warp is already installed."
fi

echo "==> [2/5] Creating /usr/local/bin/warp-port-guard.sh for ports: ${NFT_PORTS}..."
cat << EOF > /usr/local/bin/warp-port-guard.sh
#!/usr/bin/env bash
# Ports kept on the Oracle Public IP (bypassing WARP)
TCP_PORTS="${NFT_PORTS}"
UDP_PORTS="${NFT_PORTS}"
RULE_PORTS=(${ARRAY_PORTS})

IFACE=\$(ip -4 route show table main default | awk '{for(i=1;i<=NF;i++) if(\$i=="dev") print \$(i+1); exit}')
GW=\$(ip -4 route show table main default | awk '{for(i=1;i<=NF;i++) if(\$i=="via") print \$(i+1); exit}')

if [ -n "\$IFACE" ] && [ -n "\$GW" ]; then
    sysctl -qw net.ipv4.conf.all.rp_filter=2
    sysctl -qw "net.ipv4.conf.\${IFACE}.rp_filter=2"
    ip route replace default via "\$GW" dev "\$IFACE" onlink table 200
fi

while true; do
    WARP_PREF=\$(ip -4 rule show | awk -F: '/0x100cf|65743/ {gsub(/ /,"",\$1); print \$1; exit}')
    OUR_PREF=\$(ip -4 rule show | awk -F: '/lookup 200/ {gsub(/ /,"",\$1); print \$1; exit}')

    if [ -n "\$WARP_PREF" ]; then
        if [ -z "\$OUR_PREF" ] || [ "\$OUR_PREF" -ge "\$WARP_PREF" ]; then
            TARGET_PREF=\$(( WARP_PREF > 100 ? 100 : WARP_PREF - 1 ))
            while ip rule del table 200 2>/dev/null; do :; done
            for PORT in "\${RULE_PORTS[@]}"; do
                ip rule add sport "\$PORT" table 200 pref "\$TARGET_PREF"
                ip rule add dport "\$PORT" table 200 pref "\$TARGET_PREF"
            done
        fi

        if nft list table inet cloudflare-warp >/dev/null 2>&1; then
            if ! nft list chain inet cloudflare-warp input 2>/dev/null | grep -q "warp-keep-ports"; then
                nft insert rule inet cloudflare-warp input iifname "\$IFACE" tcp dport "{ \$TCP_PORTS }" accept comment \"warp-keep-ports\"
                nft insert rule inet cloudflare-warp input iifname "\$IFACE" udp dport "{ \$UDP_PORTS }" accept comment \"warp-keep-ports\"
            fi
            if ! nft list chain inet cloudflare-warp output 2>/dev/null | grep -q "warp-keep-ports"; then
                nft insert rule inet cloudflare-warp output oifname "\$IFACE" tcp sport "{ \$TCP_PORTS }" accept comment \"warp-keep-ports\"
                nft insert rule inet cloudflare-warp output oifname "\$IFACE" udp sport "{ \$UDP_PORTS }" accept comment \"warp-keep-ports\"
            fi
        fi
    else
        if [ -n "\$OUR_PREF" ]; then
            while ip rule del table 200 2>/dev/null; do :; done
        fi
    fi
    sleep 1
done
EOF
chmod +x /usr/local/bin/warp-port-guard.sh

echo "==> [3/5] Enabling and starting warp-port-guard systemd service..."
cat << 'EOF' > /etc/systemd/system/warp-port-guard.service
[Unit]
Description=Keep Public Ports (SSH/RDP) Alive on Oracle Public IP with Cloudflare WARP
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/warp-port-guard.sh
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now warp-port-guard.service
systemctl restart warp-port-guard.service
sleep 2

echo "==> [4/5] Registering and connecting Cloudflare WARP in full warp mode..."
systemctl enable --now warp-svc.service
sleep 2

# Support both newer and older warp-cli command syntax
if warp-cli --help 2>&1 | grep -q "registration"; then
    warp-cli --accept-tos registration new 2>/dev/null || true
    warp-cli --accept-tos mode warp
    warp-cli --accept-tos connect
else
    warp-cli --accept-tos register 2>/dev/null || true
    warp-cli --accept-tos set-mode warp
    warp-cli --accept-tos connect
fi

echo "==> [5/5] Waiting for WARP tunnel to stabilize..."
sleep 4

TRACE=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace || true)
WARP_STATE=$(echo "$TRACE" | awk -F= '/^warp=/ {print $2}')
WARP_IP=$(echo "$TRACE" | awk -F= '/^ip=/ {print $2}')

echo "======================================================"
echo " Cloudflare WARP Setup Complete!"
echo " Protected Public Ports : ${NFT_PORTS}"
echo " Guard Service Status   : $(systemctl is-active warp-port-guard.service)"
echo " WARP Tunnel Status     : ${WARP_STATE:-unknown}"
echo " Outbound WARP IP       : ${WARP_IP:-unknown}"
echo "======================================================"
