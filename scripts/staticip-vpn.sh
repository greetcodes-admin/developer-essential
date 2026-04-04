#!/bin/bash

# ============================================================
#  WireGuard VPN + Full Port Forwarding Setup Script
#  - Installs WireGuard on fresh server
#  - Creates 1 client automatically
#  - Forwards ALL ports (except SSH & WG) to client
#  - Handles dual IP on eth0 (DigitalOcean/cloud servers)
#  - Removes Docker if present
#  - Generates client .conf file + QR code
# ============================================================

# -------------------- Color Codes --------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# -------------------- Root Check --------------------
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}[ERROR] Please run this script as root!${NC}"
    exit 1
fi

clear
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   WireGuard VPN + Port Forward - Setup Script    ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# -------------------- Configuration --------------------
WG_INTERFACE="wg0"
WG_PORT=51820
SSH_PORT=22
SERVER_ETH="eth0"
WG_NETWORK="10.66.66.0/24"
SERVER_WG_IP="10.66.66.1"
CLIENT_WG_IP="10.66.66.2"
CLIENT_NAME="client1"
WG_DIR="/etc/wireguard"
CLIENT_CONF_OUTPUT="/root/${CLIENT_NAME}.conf"
DNS="1.1.1.1, 8.8.8.8"

# -------------------- Routing Mode --------------------
# split: Client uses LOCAL internet; only WG subnet routes via VPN
# full : Client uses SERVER internet (full tunnel); client public IP shows server IP
ROUTING_MODE="full"   # "split" or "full"

if [[ "$ROUTING_MODE" == "full" ]]; then
    CLIENT_ALLOWED_IPS="0.0.0.0/0"
    ROUTING_SUMMARY_1="${GREEN}    ✅ Client uses SERVER internet (full tunnel)${NC}"
    ROUTING_SUMMARY_2="${GREEN}    ✅ Client public IP will be server IP${NC}"
else
    CLIENT_ALLOWED_IPS="${WG_NETWORK}"
    ROUTING_SUMMARY_1="${GREEN}    ✅ Client uses LOCAL internet (not tunneled)${NC}"
    ROUTING_SUMMARY_2="${GREEN}    ✅ Only VPN subnet (${WG_NETWORK}) goes through tunnel${NC}"
fi

# ============================================================
# STEP 1: Detect Public IP on eth0 (handle dual IP)
# ============================================================
echo -e "${YELLOW}[STEP 1/10] Detecting Public IP on ${SERVER_ETH}...${NC}"

# Get all IPs on eth0
ALL_IPS=($(ip -4 addr show "$SERVER_ETH" | grep -oP '(?<=inet\s)\d+(\.\d+){3}'))

if [[ ${#ALL_IPS[@]} -eq 0 ]]; then
    echo -e "${RED}[ERROR] No IP found on ${SERVER_ETH}. Exiting.${NC}"
    exit 1
fi

# Find the public IP (not 10.x.x.x, 172.16-31.x.x, 192.168.x.x)
SERVER_PUBLIC_IP=""
for ip in "${ALL_IPS[@]}"; do
    if [[ ! "$ip" =~ ^10\. ]] && [[ ! "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && [[ ! "$ip" =~ ^192\.168\. ]] && [[ ! "$ip" =~ ^127\. ]]; then
        SERVER_PUBLIC_IP="$ip"
        break
    fi
done

if [[ -z "$SERVER_PUBLIC_IP" ]]; then
    echo -e "${RED}[ERROR] No public IP found on ${SERVER_ETH}.${NC}"
    echo -e "${YELLOW}[INFO] Found these IPs: ${ALL_IPS[*]}${NC}"
    echo -e "${YELLOW}[INPUT] Enter your server's public IP manually:${NC}"
    read -r SERVER_PUBLIC_IP
    if [[ -z "$SERVER_PUBLIC_IP" ]]; then
        echo -e "${RED}[ERROR] No IP provided. Exiting.${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}[OK] Public IP detected: ${SERVER_PUBLIC_IP}${NC}"
if [[ ${#ALL_IPS[@]} -gt 1 ]]; then
    echo -e "${YELLOW}[INFO] Multiple IPs found on ${SERVER_ETH}: ${ALL_IPS[*]}${NC}"
    echo -e "${YELLOW}[INFO] Using ${SERVER_PUBLIC_IP} for port forwarding (private IPs ignored)${NC}"
fi

# ============================================================
# STEP 2: Remove Docker if installed
# ============================================================
echo ""
echo -e "${YELLOW}[STEP 2/10] Checking & Removing Docker...${NC}"

if command -v docker &>/dev/null || systemctl is-active --quiet docker 2>/dev/null; then
    echo -e "${YELLOW}[INFO] Docker found. Removing...${NC}"

    # Stop containers
    docker stop $(docker ps -aq) 2>/dev/null
    docker rm $(docker ps -aq) 2>/dev/null

    # Stop services
    systemctl stop docker 2>/dev/null
    systemctl stop docker.socket 2>/dev/null
    systemctl stop containerd 2>/dev/null
    systemctl disable docker 2>/dev/null
    systemctl disable docker.socket 2>/dev/null
    systemctl disable containerd 2>/dev/null

    # Uninstall
    apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras 2>/dev/null
    apt-get purge -y docker docker-engine docker.io containerd runc 2>/dev/null
    yum remove -y docker docker-ce docker-ce-cli containerd.io 2>/dev/null
    dnf remove -y docker docker-ce docker-ce-cli containerd.io 2>/dev/null
    apt-get autoremove -y 2>/dev/null

    # Remove data
    rm -rf /var/lib/docker
    rm -rf /var/lib/containerd
    rm -rf /etc/docker
    rm -rf /run/docker
    rm -rf /run/docker.sock

    echo -e "${GREEN}[OK] Docker removed completely.${NC}"
else
    echo -e "${GREEN}[OK] Docker not found. Skipping.${NC}"
fi

# ============================================================
# STEP 3: Cleanup existing WireGuard + flush iptables (clean slate)
# ============================================================
echo ""
echo -e "${YELLOW}[STEP 3/10] Cleaning existing WireGuard + flushing iptables (clean slate)...${NC}"

# --- Clean existing WireGuard state (if any) ---
if systemctl list-unit-files 2>/dev/null | grep -q "^wg-quick@"; then
    systemctl stop wg-quick@${WG_INTERFACE} 2>/dev/null || true
    systemctl disable wg-quick@${WG_INTERFACE} >/dev/null 2>&1 || true
fi

if command -v wg-quick &>/dev/null; then
    wg-quick down ${WG_INTERFACE} 2>/dev/null || true
fi

if [[ -f "${WG_DIR}/${WG_INTERFACE}.conf" ]]; then
    TS=$(date +%Y%m%d%H%M%S)
    mv "${WG_DIR}/${WG_INTERFACE}.conf" "${WG_DIR}/${WG_INTERFACE}.conf.bak.${TS}" 2>/dev/null || true
fi

iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -t raw -F
iptables -X
iptables -t nat -X
iptables -t mangle -X
iptables -t raw -X

iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

echo -e "${GREEN}[OK] Existing WireGuard cleaned + iptables flushed. Clean slate.${NC}"

# ============================================================
# STEP 4: Disable UFW / firewalld if active
# ============================================================
echo ""
echo -e "${YELLOW}[STEP 4/10] Disabling UFW / firewalld if active...${NC}"

if command -v ufw &>/dev/null; then
    ufw disable 2>/dev/null
    echo -e "${GREEN}[OK] UFW disabled.${NC}"
fi

if systemctl is-active --quiet firewalld 2>/dev/null; then
    systemctl stop firewalld
    systemctl disable firewalld
    echo -e "${GREEN}[OK] firewalld disabled.${NC}"
fi

echo -e "${GREEN}[OK] Firewall check done.${NC}"

# ============================================================
# STEP 5: Install WireGuard
# ============================================================
echo ""
echo -e "${YELLOW}[STEP 5/10] Installing WireGuard...${NC}"

if command -v apt-get &>/dev/null; then
    apt-get update -y
    apt-get install -y wireguard wireguard-tools qrencode iptables
elif command -v yum &>/dev/null; then
    yum install -y epel-release
    yum install -y wireguard-tools qrencode iptables
elif command -v dnf &>/dev/null; then
    dnf install -y wireguard-tools qrencode iptables
else
    echo -e "${RED}[ERROR] Unsupported package manager. Exiting.${NC}"
    exit 1
fi

if ! command -v wg &>/dev/null; then
    echo -e "${RED}[ERROR] WireGuard installation failed. Exiting.${NC}"
    exit 1
fi

echo -e "${GREEN}[OK] WireGuard installed.${NC}"

# ============================================================
# STEP 6: Enable IP Forwarding
# ============================================================
echo ""
echo -e "${YELLOW}[STEP 6/10] Enabling IP Forwarding...${NC}"

# Enable now
echo 1 > /proc/sys/net/ipv4/ip_forward

# Persist
if grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf; then
    sed -i 's/^.*net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
else
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
fi

sysctl -p /etc/sysctl.conf >/dev/null 2>&1

IPFWD=$(cat /proc/sys/net/ipv4/ip_forward)
if [[ "$IPFWD" == "1" ]]; then
    echo -e "${GREEN}[OK] IP Forwarding enabled.${NC}"
else
    echo -e "${RED}[ERROR] IP Forwarding could not be enabled. Exiting.${NC}"
    exit 1
fi

# ============================================================
# STEP 7: Generate Keys
# ============================================================
echo ""
echo -e "${YELLOW}[STEP 7/10] Generating Server & Client Keys...${NC}"

mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"

SERVER_PRIVATE_KEY=$(wg genkey)
SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)

CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
CLIENT_PRESHARED_KEY=$(wg genpsk)

echo -e "${GREEN}[OK] All keys generated.${NC}"

# ============================================================
# STEP 8: Create Server Config
# ============================================================
echo ""
echo -e "${YELLOW}[STEP 8/10] Creating WireGuard Server Config...${NC}"

cat > "${WG_DIR}/${WG_INTERFACE}.conf" << EOF
[Interface]
Address = ${SERVER_WG_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}

# ---- PostUp: Apply iptables rules ----

# DNAT: Forward all TCP/UDP to client (except SSH & WG port)
# Using -d PUBLIC_IP to handle dual IP on eth0
PostUp = iptables -t nat -A PREROUTING -p tcp -d ${SERVER_PUBLIC_IP} -m multiport ! --dports ${SSH_PORT},${WG_PORT} -j DNAT --to-destination ${CLIENT_WG_IP}
PostUp = iptables -t nat -A PREROUTING -p udp -d ${SERVER_PUBLIC_IP} -m multiport ! --dports ${SSH_PORT},${WG_PORT} -j DNAT --to-destination ${CLIENT_WG_IP}

# MASQUERADE on wg0: So client sees traffic from server WG IP (return path fix)
PostUp = iptables -t nat -A POSTROUTING -o ${WG_INTERFACE} -j MASQUERADE

# MASQUERADE on eth0: For VPN clients accessing internet
PostUp = iptables -t nat -A POSTROUTING -s ${WG_NETWORK} -o ${SERVER_ETH} -j MASQUERADE

# FORWARD: Allow traffic between eth0 and wg0
PostUp = iptables -A FORWARD -i ${SERVER_ETH} -o ${WG_INTERFACE} -d ${CLIENT_WG_IP} -j ACCEPT
PostUp = iptables -A FORWARD -i ${WG_INTERFACE} -o ${SERVER_ETH} -s ${CLIENT_WG_IP} -j ACCEPT
PostUp = iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# ---- PostDown: Cleanup iptables rules ----
PostDown = iptables -t nat -D PREROUTING -p tcp -d ${SERVER_PUBLIC_IP} -m multiport ! --dports ${SSH_PORT},${WG_PORT} -j DNAT --to-destination ${CLIENT_WG_IP}
PostDown = iptables -t nat -D PREROUTING -p udp -d ${SERVER_PUBLIC_IP} -m multiport ! --dports ${SSH_PORT},${WG_PORT} -j DNAT --to-destination ${CLIENT_WG_IP}
PostDown = iptables -t nat -D POSTROUTING -o ${WG_INTERFACE} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${WG_NETWORK} -o ${SERVER_ETH} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${SERVER_ETH} -o ${WG_INTERFACE} -d ${CLIENT_WG_IP} -j ACCEPT
PostDown = iptables -D FORWARD -i ${WG_INTERFACE} -o ${SERVER_ETH} -s ${CLIENT_WG_IP} -j ACCEPT
PostDown = iptables -D FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

[Peer]
# ${CLIENT_NAME}
PublicKey = ${CLIENT_PUBLIC_KEY}
PresharedKey = ${CLIENT_PRESHARED_KEY}
AllowedIPs = ${CLIENT_WG_IP}/32
EOF

chmod 600 "${WG_DIR}/${WG_INTERFACE}.conf"
echo -e "${GREEN}[OK] Server config: ${WG_DIR}/${WG_INTERFACE}.conf${NC}"

# ============================================================
# STEP 9: Create Client Config
# ============================================================
echo ""
echo -e "${YELLOW}[STEP 9/10] Generating Client Config...${NC}"

cat > "$CLIENT_CONF_OUTPUT" << EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${CLIENT_WG_IP}/24
DNS = ${DNS}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
PresharedKey = ${CLIENT_PRESHARED_KEY}
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
AllowedIPs = ${CLIENT_ALLOWED_IPS}
PersistentKeepalive = 25
EOF

chmod 600 "$CLIENT_CONF_OUTPUT"
echo -e "${GREEN}[OK] Client config: ${CLIENT_CONF_OUTPUT}${NC}"

# ============================================================
# STEP 10: Start WireGuard
# ============================================================
echo ""
echo -e "${YELLOW}[STEP 10/10] Starting WireGuard...${NC}"

# Stop if running
systemctl stop wg-quick@${WG_INTERFACE} 2>/dev/null

# Enable & start
systemctl enable wg-quick@${WG_INTERFACE} >/dev/null 2>&1
systemctl start wg-quick@${WG_INTERFACE}

sleep 2

if systemctl is-active --quiet wg-quick@${WG_INTERFACE}; then
    echo -e "${GREEN}[OK] WireGuard is running!${NC}"
else
    echo -e "${RED}[ERROR] WireGuard failed to start!${NC}"
    echo -e "${RED}Check: journalctl -xeu wg-quick@${WG_INTERFACE}${NC}"
    exit 1
fi

# ============================================================
# Verify iptables rules
# ============================================================
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║            IPTABLES VERIFICATION                ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}=== NAT PREROUTING ===${NC}"
iptables -t nat -L PREROUTING -n -v --line-numbers
echo ""
echo -e "${BOLD}=== NAT POSTROUTING ===${NC}"
iptables -t nat -L POSTROUTING -n -v --line-numbers
echo ""
echo -e "${BOLD}=== FORWARD ===${NC}"
iptables -L FORWARD -n -v --line-numbers
echo ""
echo -e "${BOLD}=== FORWARD Policy ===${NC}"
iptables -L FORWARD -n | head -1

# ============================================================
# QR Code for mobile
# ============================================================
echo ""
echo -e "${CYAN}╔══════════════════════════════════���═══════════════╗${NC}"
echo -e "${CYAN}║          CLIENT QR CODE (Scan with app)         ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
qrencode -t ansiutf8 < "$CLIENT_CONF_OUTPUT" 2>/dev/null || echo -e "${YELLOW}(qrencode not available)${NC}"

# ============================================================
# Final Summary
# ============================================================
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║             SETUP COMPLETE - SUMMARY            ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}  Server Public IP    : ${SERVER_PUBLIC_IP}${NC}"
echo -e "${GREEN}  Server WG IP        : ${SERVER_WG_IP}${NC}"
echo -e "${GREEN}  Client WG IP        : ${CLIENT_WG_IP}${NC}"
echo -e "${GREEN}  WireGuard Port      : ${WG_PORT}/udp${NC}"
echo -e "${GREEN}  SSH Port            : ${SSH_PORT}/tcp${NC}"
echo -e "${GREEN}  Interface           : ${WG_INTERFACE}${NC}"
echo -e "${GREEN}  Client Config File  : ${CLIENT_CONF_OUTPUT}${NC}"
echo ""
echo -e "${BOLD}  Routing Mode:${NC}"
echo -e "${ROUTING_SUMMARY_1}"
echo -e "${ROUTING_SUMMARY_2}"
echo ""
echo -e "${BOLD}  Port Forwarding:${NC}"
echo -e "${GREEN}    ✅ ALL TCP/UDP ports on ${SERVER_PUBLIC_IP} → ${CLIENT_WG_IP}${NC}"
echo -e "${RED}    ❌ EXCLUDED: Port ${SSH_PORT} (SSH)${NC}"
echo -e "${RED}    ❌ EXCLUDED: Port ${WG_PORT} (WireGuard)${NC}"
echo ""
echo -e "${BOLD}  Dual IP Handling:${NC}"
echo -e "${GREEN}    ✅ Uses -d ${SERVER_PUBLIC_IP} (not -i eth0)${NC}"
echo -e "${GREEN}    ✅ Private IPs on eth0 are ignored${NC}"
echo ""
echo -e "${BOLD}  Key Fix Applied:${NC}"
echo -e "${GREEN}    ✅ MASQUERADE on wg0 (return path fix for DNAT)${NC}"
echo ""
echo -e "${CYAN}  ─── Useful Commands ───${NC}"
echo -e "  wg show                                  # WG status"
echo -e "  systemctl status wg-quick@${WG_INTERFACE}          # Service status"
echo -e "  systemctl restart wg-quick@${WG_INTERFACE}         # Restart WG"
echo -e "  iptables -t nat -L -n -v                 # Check NAT rules"
echo -e "  tcpdump -i eth0 port 8080 -n             # Debug traffic"
echo ""
echo -e "${CYAN}  ─── Transfer Config to Device ───${NC}"
echo -e "  scp root@${SERVER_PUBLIC_IP}:${CLIENT_CONF_OUTPUT} ."
echo ""
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"