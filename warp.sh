#!/usr/bin/env bash
set -e

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use: sudo bash install-warp.sh)"
    exit 1
fi

# Always protect SSH (22) and RDP (3389), plus any extra ports passed as arguments
BASE_PORTS=(22 3389)
ALL_PORTS=("${BASE_PORTS[@]}" "$@")

# Deduplicate ports and format for iptables (comma-separated)
UNIQUE_PORTS=($(printf "%s\n" "${ALL_PORTS[@]}" | awk '/^[0-9]+$/' | sort -nu))
COMMA_PORTS=$(IFS=,; echo "${UNIQUE_PORTS[*]}")

echo "==> [1/5] Installing prerequisites and official Cloudflare WARP repository..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl gpg iptables iproute2 lsb-release ca-certificates

if ! command -v warp-cli >/dev/null 2>&1; then
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main" > /etc/apt/sources.list.d/cloudflare-client.list
    apt-get update -y
    apt-get install -y cloudflare-warp
else
    echo "    cloudflare-warp is already installed."
fi

echo "==> [2/5] Creating /usr/local/bin/warp-port-guard.sh for ports: ${COMMA_PORTS}..."
cat << EOF > /usr/local/bin/warp-port-guard.sh
#!/usr/bin/env bash
# Connection Marking Script: Bypasses WARP for incoming public traffic
PORTS="${COMMA_PORTS}"

IFACE=\$(ip -4 route show table main default | awk '{for(i=1;i<=NF;i++) if(\$i=="dev") print \$(i+1); exit}')
GW=\$(ip -4 route show table main default | awk '{for(i=1;i<=NF;i++) if(\$i=="via") print \$(i+1); exit}')

if [ -z "\$IFACE" ] || [ -z "\$GW" ]; then
    echo "Waiting for network..."
    sleep 5
    exit 0
fi

# 1. Ensure table 200 routes back out the physical gateway
ip route replace default via "\$GW" dev "\$IFACE" onlink table 200

# 2. Add an IP rule to look up table 200 for marked packets
if ! ip rule show | grep -q "fwmark 0x200 lookup 200"; then
    ip rule add fwmark 0x200 pref 99 table 200
fi

while true; do
    # 3. TCP: Mark incoming connections and restore mark on outgoing replies
    if ! iptables -t mangle -C PREROUTING -i "\$IFACE" -p tcp -m multiport --dports "\$PORTS" -j CONNMARK --set-mark 0x200 2>/dev/null; then
        iptables -t mangle -A PREROUTING -i "\$IFACE" -p tcp -m multiport --dports "\$PORTS" -j CONNMARK --set-mark 0x200
    fi
    if ! iptables -t mangle -C OUTPUT -p tcp -m multiport --sports "\$PORTS" -j CONNMARK --restore-mark 2>/dev/null; then
        iptables -t mangle -A OUTPUT -p tcp -m multiport --sports "\$PORTS" -j CONNMARK --restore-mark
    fi

    # 4. UDP: Mark incoming connections and restore mark on outgoing replies
    if ! iptables -t mangle -C PREROUTING -i "\$IFACE" -p udp -m multiport --dports "\$PORTS" -j CONNMARK --set-mark 0x200 2>/dev/null; then
        iptables -t mangle -A PREROUTING -i "\$IFACE" -p udp -m multiport --dports "\$PORTS" -j CONNMARK --set-mark 0x200
    fi
    if ! iptables -t mangle -C OUTPUT -p udp -m multiport --sports "\$PORTS" -j CONNMARK --restore-mark 2>/dev/null; then
        iptables -t mangle -A OUTPUT -p udp -m multiport --sports "\$PORTS" -j CONNMARK --restore-mark
    fi

    sleep 5
done
EOF
chmod +x /usr/local/bin/warp-port-guard.sh

echo "==> [3/5] Enabling and starting warp-port-guard systemd service..."
cat << 'EOF' > /etc/systemd/system/warp-port-guard.service
[Unit]
Description=Keep Public Ports (SSH/RDP) Alive via iptables CONNMARK
After=network-online.target iptables.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/warp-port-guard.sh
Restart=always
RestartSec=3

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
echo " Cloudflare WARP Setup Complete (Robust IPTables Mode)!"
echo " Protected Public Ports : ${COMMA_PORTS}"
echo " Guard Service Status   : $(systemctl is-active warp-port-guard.service)"
echo " WARP Tunnel Status     : ${WARP_STATE:-unknown}"
echo " Outbound WARP IP       : ${WARP_IP:-unknown}"
echo "======================================================"
