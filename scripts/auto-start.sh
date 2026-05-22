#!/bin/bash
# auto-start.sh - Automated startup script for 5G eBPF QoS system

set -e

echo "Starting 5G eBPF QoS System..."

# [1/11] Configure network
echo "[1/11] Configuring network..."
INTERNET_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
echo "       Using internet interface: $INTERNET_IFACE"
sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
echo "       Network configured"

# Clean up old Docker networks
echo "       Cleaning up old networks..."
docker network rm deployment_privnet 2>/dev/null || true

# [2/11] Start Docker Compose
echo "[2/11] Starting Docker containers..."
cd deployment
docker compose up -d
cd ..

# [3/11] Wait for services
echo "[3/11] Waiting for services to be ready..."
echo "       Waiting for MongoDB (30s)..."
sleep 30

# Check MongoDB
for i in {1..30}; do
    if docker exec mongodb mongo --eval "db.runCommand('ping').ok" free5gc > /dev/null 2>&1; then
        echo "       MongoDB ready"
        break
    fi
    sleep 1
done

# [3.5/11] Provision subscriber
echo "[3/11] Provisioning subscriber..."
./scripts/provision-subscriber.sh

# [4/11] Start UE
echo "[4/11] Starting UE..."
docker exec -d ueransim bash -c './nr-ue -c ./config/uecfg.yaml > /tmp/ue.log 2>&1'

# Wait for UE registration
echo "       Waiting for UE registration..."
for i in {1..20}; do
    if docker exec ueransim ip addr show uesimtun0 2>/dev/null | grep -q "inet "; then
        UE_IP=$(docker exec ueransim ip addr show uesimtun0 | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
        echo "       SUCCESS: UE registered with IP: $UE_IP"
        break
    fi
    sleep 2
done

if [ -z "$UE_IP" ]; then
    echo "       ERROR: UE registration failed!"
    echo "       Check logs: docker logs ueransim"
    exit 1
fi

# [5/11] Test connectivity
echo "[5/11] Testing connectivity..."
if docker exec ueransim ping -I uesimtun0 -c 3 -W 5 8.8.8.8 > /dev/null 2>&1; then
    echo "       SUCCESS: Internet connectivity working"
else
    echo "       WARNING: Connectivity test failed"
fi

# [6/11] Auto-detect veth interface
echo "[6/11] Auto-detecting veth interface..."
# Generate traffic first
docker exec ueransim ping -I uesimtun0 -c 5 8.8.8.8 > /dev/null 2>&1 &

# Capture GTP-U traffic and extract veth name
VETH=$(sudo timeout 5 tcpdump -i any -nn port 2152 -c 1 2>&1 | grep -E "veth.*IP.*2152.*2152" | head -1 | awk '{print $2}')

# Fallback: Get the most recently created veth on br-free5gc
if [ -z "$VETH" ]; then
    echo "       Trying fallback method..."
    VETH=$(ip link show | grep -E "veth.*master.*free5gc" | tail -1 | awk '{print $2}' | cut -d'@' -f1 | cut -d':' -f1)
fi

if [ -z "$VETH" ]; then
    echo "       ERROR: Could not auto-detect veth interface!"
    echo "       Available veth interfaces:"
    ip link show | grep veth
    echo ""
    echo "       Manually run: sudo ./ebpf-qos/qos_manager.py load --interface <veth_name>"
    exit 1
fi

echo "       SUCCESS: Using interface: $VETH"

# [7/11] Auto-detect TEID
echo "[7/11] Auto-detecting TEID..."
# Generate traffic
docker exec ueransim ping -I uesimtun0 -c 3 8.8.8.8 > /dev/null 2>&1 &

# Capture packet and extract TEID from hex
TEID_HEX=$(sudo timeout 5 tcpdump -i $VETH -nn port 2152 -X -c 1 2>&1 | grep "0x0020:" | head -1 | awk '{print $2$3}')

if [ -z "$TEID_HEX" ]; then
    echo "       ERROR: Could not detect TEID from packet capture"
    echo "       Hex dump:"
    sudo timeout 5 tcpdump -i $VETH -nn port 2152 -X -c 1 2>&1 || true
    exit 1
fi

# Convert hex to decimal (first 4 bytes after 0x0020)
TEID=$((16#${TEID_HEX:0:8}))
echo "       SUCCESS: Detected TEID: $TEID"

# [8/11] Build and load eBPF
echo "[8/11] Building and loading eBPF program..."
cd ebpf-qos

# Build if not already built
if [ ! -f "gtp_qos.bpf.o" ]; then
    echo "       Building eBPF object file..."
    make > /dev/null 2>&1
fi

sudo ./qos_manager.py load --interface $VETH
cd ..
echo "       eBPF loaded on $VETH"

# [9/11] Set default policy
echo "[9/11] Setting default QoS policy (ALLOW)..."
sudo ./ebpf-qos/qos_manager.py policy --teid $TEID --action 0
echo "       Policy set: TEID $TEID -> ALLOW"

# [10/11] Verify setup
echo "[10/11] Verifying setup..."
if docker exec ueransim ping -I uesimtun0 -c 3 -W 5 8.8.8.8 > /dev/null 2>&1; then
    echo "       ✓ Connectivity test passed"
else
    echo "       ✗ Connectivity test failed"
fi

# [11/11] Display summary
echo ""
echo "=========================================="
echo "5G eBPF QoS System Ready!"
echo "=========================================="
echo "UE IP:        $UE_IP"
echo "TEID:         $TEID"
echo "veth:         $VETH"
echo "eBPF:         Loaded"
echo "Policy:       ALLOW"
echo ""
echo "Test QoS policies:"
echo "  DROP:  sudo ./ebpf-qos/qos_manager.py policy --teid $TEID --action 1"
echo "  ALLOW: sudo ./ebpf-qos/qos_manager.py policy --teid $TEID --action 0"
echo ""
echo "Test connectivity:"
echo "  docker exec ueransim ping -I uesimtun0 -c 5 8.8.8.8"
echo ""
echo "View stats:"
echo "  sudo bpftool map dump name stats_map"
echo "=========================================="
