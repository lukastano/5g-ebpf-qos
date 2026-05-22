#!/bin/bash
# auto-start.sh - Fully automated startup with auto-detection

set -e

echo "Starting 5G eBPF QoS System..."
echo ""

# 1. Network configuration
echo "[1/10] Configuring network..."
sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null

# Check which internet interface to use
INET_IF=$(ip route | grep default | awk '{print $5}' | head -1)
echo "       Using internet interface: $INET_IF"

sudo iptables -t nat -C POSTROUTING -o $INET_IF -j MASQUERADE 2>/dev/null || \
    sudo iptables -t nat -A POSTROUTING -o $INET_IF -j MASQUERADE
sudo iptables -C FORWARD 1 -j ACCEPT 2>/dev/null || \
    sudo iptables -I FORWARD 1 -j ACCEPT

echo "       Network configured"

# 2. Start Docker
echo ""
echo "[2/10] Starting Docker containers..."
cd deployment

# Clean start
docker compose down > /dev/null 2>&1 || true
docker compose up -d

# Wait for services
echo "       Waiting for services to start (30 seconds)..."
sleep 30

# Check container status
RUNNING=$(docker compose ps | grep -c "Up" || echo "0")
TOTAL=$(docker compose ps | wc -l)
TOTAL=$((TOTAL - 1)) # Subtract header line

if [ "$RUNNING" -ge 15 ]; then
    echo "       SUCCESS: $RUNNING/$TOTAL containers running"
else
    echo "       WARNING: Only $RUNNING/$TOTAL containers running"
    docker compose ps
fi

cd ..

# 3. Start UE
echo ""
echo "[3/10] Starting UE..."
docker exec -d ueransim bash -c './nr-ue -c ./config/uecfg.yaml > /tmp/ue.log 2>&1'

# Wait for UE registration
echo "       Waiting for UE registration..."
for i in {1..20}; do
    if docker exec ueransim ip addr show uesimtun0 > /dev/null 2>&1; then
        break
    fi
    sleep 1
done

if docker exec ueransim ip addr show uesimtun0 > /dev/null 2>&1; then
    UE_IP=$(docker exec ueransim ip addr show uesimtun0 | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
    echo "       SUCCESS: UE registered with IP: $UE_IP"
else
    echo "       ERROR: UE registration failed!"
    echo "       Check logs: docker logs ueransim"
    exit 1
fi

# 4. Test connectivity
echo ""
echo "[4/10] Testing connectivity..."
if timeout 5 docker exec ueransim ping -I uesimtun0 -c 2 -W 2 8.8.8.8 > /dev/null 2>&1; then
    echo "       SUCCESS: Internet connectivity working"
else
    echo "       ERROR: Connectivity test failed"
    exit 1
fi

# 5. Auto-detect veth interface
echo ""
echo "[5/10] Auto-detecting veth interface..."

# Method: Find veth with GTP-U traffic (port 2152)
sudo timeout 10 tcpdump -i any -nn port 2152 -c 1 > /tmp/veth_detect.txt 2>&1 &
TCPDUMP_PID=$!

sleep 2
# Generate traffic
docker exec ueransim ping -I uesimtun0 -c 5 8.8.8.8 > /dev/null 2>&1 &

wait $TCPDUMP_PID 2>/dev/null || true

VETH=$(grep "listening on" /tmp/veth_detect.txt 2>/dev/null | awk '{print $4}' | head -1 | sed 's/,//')

# Fallback: Get the most recently created veth on br-free5gc
if [ -z "$VETH" ] || [ "$VETH" = "any" ]; then
    echo "       Trying fallback method..."
    VETH=$(ip link show | grep -E "veth.*master br-free5gc" | tail -1 | awk '{print $2}' | cut -d'@' -f1 | cut -d':' -f1)
fi

if [ -z "$VETH" ]; then
    echo "       ERROR: Could not auto-detect veth interface!"
    echo "       Available veth interfaces:"
    ip link show | grep veth
    echo ""
    echo "       Manually specify with: sudo ./ebpf-qos/qos_manager.py load --interface <veth_name>"
    exit 1
fi

echo "       SUCCESS: Using interface: $VETH"

# 6. Auto-detect TEID
echo ""
echo "[6/10] Auto-detecting TEID..."

sudo timeout 8 tcpdump -i $VETH -nn port 2152 -X -c 1 > /tmp/teid_detect.txt 2>&1 &
sleep 2
docker exec ueransim ping -I uesimtun0 -c 3 8.8.8.8 > /dev/null 2>&1
sleep 4

# Extract TEID from hex dump at offset 0x0020
TEID_HEX=$(grep "0x0020:" /tmp/teid_detect.txt 2>/dev/null | head -1 | awk '{print $2}')

if [ -z "$TEID_HEX" ]; then
    echo "       ERROR: Could not detect TEID from packet capture"
    echo "       Hex dump:"
    cat /tmp/teid_detect.txt
    exit 1
fi

# Convert hex to decimal
TEID=$((16#$TEID_HEX))

if [ $TEID -eq 0 ]; then
    echo "       ERROR: Invalid TEID detected: $TEID"
    exit 1
fi

echo "       SUCCESS: Detected TEID: $TEID"

# 7. Load eBPF
echo ""
echo "[7/10] Loading eBPF QoS program..."
cd ebpf-qos

# Unload if already loaded
sudo ./qos_manager.py unload --interface $VETH 2>/dev/null || true

# Load
if sudo ./qos_manager.py load --interface $VETH; then
    echo "       SUCCESS: eBPF loaded on $VETH"
else
    echo "       ERROR: eBPF load failed!"
    exit 1
fi

# 8. Set initial ALLOW policy
echo ""
echo "[8/10] Setting initial policy..."
if sudo ./qos_manager.py policy --teid $TEID --action 0; then
    echo "       SUCCESS: Initial policy: TEID $TEID -> ALLOW"
else
    echo "       WARNING: Policy set may have failed"
fi

cd ..

# 9. Save state
cat > /tmp/qos_state.env << ENVEOF
VETH=$VETH
TEID=$TEID
UE_IP=$UE_IP
INET_IF=$INET_IF
ENVEOF

# 10. Verify eBPF is working
echo ""
echo "[9/10] Verifying eBPF..."
sleep 2
docker exec ueransim ping -I uesimtun0 -c 3 8.8.8.8 > /dev/null 2>&1

PACKET_COUNT=$(sudo bpftool map dump name stats_map 2>/dev/null | grep -c "key" || echo "0")

if [ $PACKET_COUNT -gt 0 ]; then
    echo "       SUCCESS: eBPF processing packets ($PACKET_COUNT TEIDs seen)"
else
    echo "       WARNING: eBPF loaded but no packets processed yet"
fi

# 11. Final summary
echo ""
echo "[10/10] Startup complete"
echo ""
echo "=========================================="
echo "5G eBPF QoS System is Ready"
echo "=========================================="
echo ""
echo "Configuration:"
echo "  Interface:  $VETH"
echo "  TEID:       $TEID"
echo "  UE IP:      $UE_IP"
echo "  Policy:     ALLOW (traffic flowing)"
echo ""
echo "Commands:"
echo "  Block traffic:   ./scripts/set-policy.sh DROP"
echo "  Allow traffic:   ./scripts/set-policy.sh ALLOW"
echo "  View stats:      ./scripts/show-stats.sh"
echo "  Stop system:     ./scripts/stop.sh"
echo ""
echo "Test:"
echo "  docker exec ueransim ping -I uesimtun0 -c 5 8.8.8.8"
echo ""
