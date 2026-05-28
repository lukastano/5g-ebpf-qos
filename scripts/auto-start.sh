#!/bin/bash
# auto-start.sh - Automated startup script for 5G eBPF QoS system (Dual UE)

set -e

echo "Starting 5G eBPF QoS System..."

########################################
# [1/12] Configure network
########################################

echo "[1/12] Configuring network..."

INTERNET_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)

echo "       Using internet interface: $INTERNET_IFACE"

sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null

echo "       Network configured"

echo "       Cleaning up old networks..."

docker network rm deployment_privnet 2>/dev/null || true

########################################
# [2/12] Start Docker Compose
########################################

echo "[2/12] Starting Docker containers..."

cd deployment
docker compose up -d --build
cd ..

########################################
# [3/12] Wait for services
########################################

echo "[3/12] Waiting for services to be ready..."

echo "       Waiting for MongoDB (30s)..."

sleep 30

for i in {1..30}; do

    if docker exec mongodb \
        mongo --eval "db.runCommand('ping').ok" free5gc \
        > /dev/null 2>&1; then

        echo "       MongoDB ready"
        break
    fi

    sleep 1

done

########################################
# [4/12] Provision subscribers
########################################

echo "[4/12] Provisioning subscribers..."

./scripts/provision-subscriber.sh

########################################
# [5/12] Start UE1 + UE2
########################################

echo "[5/12] Starting UE1..."

docker exec -d ueransim \
    bash -c './nr-ue -c ./config/uecfg.yaml > /tmp/ue1.log 2>&1'

sleep 3

echo "[5/12] Starting UE2..."

docker exec -d ueransim \
    bash -c './nr-ue -c ./config/ue2cfg.yaml > /tmp/ue2.log 2>&1'

########################################
# [6/12] Wait for UE registration
########################################

echo "[6/12] Waiting for UE registration..."

############################
# UE1
############################

for i in {1..30}; do

    if docker exec ueransim \
        ip addr show uesimtun0 2>/dev/null | grep -q "inet "; then

        UE1_IP=$(docker exec ueransim \
            ip addr show uesimtun0 |
            grep "inet " |
            awk '{print $2}' |
            cut -d'/' -f1)

        echo "       SUCCESS: UE1 registered with IP: $UE1_IP"

        break
    fi

    sleep 2

done

if [ -z "$UE1_IP" ]; then

    echo "       ERROR: UE1 registration failed!"
    echo "       Check logs:"
    echo "       docker exec ueransim cat /tmp/ue1.log"

    exit 1

fi

############################
# UE2
############################

for i in {1..30}; do

    if docker exec ueransim \
        ip addr show uesimtun1 2>/dev/null | grep -q "inet "; then

        UE2_IP=$(docker exec ueransim \
            ip addr show uesimtun1 |
            grep "inet " |
            awk '{print $2}' |
            cut -d'/' -f1)

        echo "       SUCCESS: UE2 registered with IP: $UE2_IP"

        break
    fi

    sleep 2

done

if [ -z "$UE2_IP" ]; then

    echo "       ERROR: UE2 registration failed!"
    echo "       Check logs:"
    echo "       docker exec ueransim cat /tmp/ue2.log"

    exit 1

fi

########################################
# [7/12] Test connectivity
########################################

echo "[7/12] Testing connectivity..."

if docker exec ueransim \
    ping -I uesimtun0 -c 3 -W 5 8.8.8.8 \
    > /dev/null 2>&1; then

    echo "       SUCCESS: UE1 internet connectivity working"

else

    echo "       WARNING: UE1 connectivity test failed"

fi

if docker exec ueransim \
    ping -I uesimtun1 -c 3 -W 5 8.8.8.8 \
    > /dev/null 2>&1; then

    echo "       SUCCESS: UE2 internet connectivity working"

else

    echo "       WARNING: UE2 connectivity test failed"

fi

########################################
# [8/12] Detect UE1 veth
########################################

echo "[8/12] Detecting UE1 veth..."

docker exec ueransim \
    ping -I uesimtun0 -c 5 8.8.8.8 \
    > /dev/null 2>&1 &

UE1_VETH=$(sudo timeout 5 tcpdump \
    -i any \
    -nn port 2152 \
    -c 5 2>&1 |
    grep "Out" |
    grep -E "veth.*IP.*2152.*2152" |
    head -1 |
    awk '{print $2}')

if [ -z "$UE1_VETH" ]; then

    echo "       ERROR: Failed to detect UE1 veth"

    exit 1

fi

echo "       SUCCESS: UE1 uses veth: $UE1_VETH"

########################################
# [8/12] Detect UE2 veth
########################################

echo "[8/12] Detecting UE2 veth..."

docker exec ueransim \
    ping -I uesimtun1 -c 5 8.8.8.8 \
    > /dev/null 2>&1 &

UE2_VETH=$(sudo timeout 5 tcpdump \
    -i any \
    -nn port 2152 \
    -c 5 2>&1 |
    grep "Out" |
    grep -E "veth.*IP.*2152.*2152" |
    head -1 |
    awk '{print $2}')

if [ -z "$UE2_VETH" ]; then

    echo "       ERROR: Failed to detect UE2 veth"

    exit 1

fi

echo "       SUCCESS: UE2 uses veth: $UE2_VETH"

########################################
# Compare
########################################

echo ""
echo "=========================================="
echo "VETH TOPOLOGY"
echo "=========================================="

echo "UE1 veth: $UE1_VETH"
echo "UE2 veth: $UE2_VETH"

if [ "$UE1_VETH" = "$UE2_VETH" ]; then

    echo ""
    echo "RESULT: Shared dataplane detected"
    echo "        Multiple TEIDs share same interface"

    VETH=$UE1_VETH

else

    echo ""
    echo "RESULT: Separate dataplanes detected"
    echo "        Each UE uses different interface"
    exit 1
fi

echo "=========================================="

########################################
# [9/12] Auto-detect TEIDs
########################################

echo "[9/12] Auto-detecting TEIDs..."

################################
# Generate traffic
################################

GNB_IP=$(docker exec ueransim ip -4 addr show eth0 | 
    grep -oP '(?<=inet\s)\d+(\.\d+){3}')

docker exec ueransim \
    ping -I uesimtun0 -c 5 8.8.8.8 \
    > /dev/null 2>&1 &

docker exec ueransim \
    ping -I uesimtun1 -c 5 8.8.8.8 \
    > /dev/null 2>&1 &

sleep 2

################################
# Capture TEIDs
################################

TEIDS=$(sudo timeout 5 tcpdump \
    -i $VETH \
    -nn "src host $GNB_IP and udp port 2152" \
    -X -c 10 2>/dev/null |
    grep "0x0020:" |
    awk '{print $2$3}' |
    cut -c1-8 |
    sort -u)

TEID1=$(echo "$TEIDS" | head -1)
TEID2=$(echo "$TEIDS" | tail -1)

if [ -z "$TEID1" ] || [ -z "$TEID2" ]; then

    echo "       ERROR: Failed to detect both TEIDs"

    exit 1

fi

TEID1_DEC=$((16#$TEID1))
TEID2_DEC=$((16#$TEID2))

echo "       SUCCESS: UE1 TEID = $TEID1_DEC"
echo "       SUCCESS: UE2 TEID = $TEID2_DEC"

########################################
# [10/12] Build and load eBPF
########################################

echo "[10/12] Building and loading eBPF program..."

cd ebpf-qos

if [ ! -f "gtp_qos.bpf.o" ]; then

    echo "       Building eBPF object file..."

    make > /dev/null 2>&1

fi

sudo ./qos_manager.py load --interface $VETH

cd ..

echo "       eBPF loaded on $VETH"

########################################
# [11/12] Configure QoS policies
########################################

echo "[11/12] Configuring QoS policies..."

################################
# UE1 = High priority
################################

sudo ./ebpf-qos/qos_manager.py policy \
    --interface $VETH \
    --teid $TEID1_DEC \
    --action 0 \
    --priority 0 \
    --rate 20

################################
# UE2 = Low priority
################################

sudo ./ebpf-qos/qos_manager.py policy \
    --interface $VETH \
    --teid $TEID2_DEC \
    --action 0 \
    --priority 3 \
    --rate 5

echo "       UE1 -> HIGH priority / 20mbit"
echo "       UE2 -> LOW priority / 5mbit"

########################################
# [12/12] Summary
########################################

echo ""
echo "=========================================="
echo "5G eBPF QoS System Ready!"
echo "=========================================="

echo "Interface:      $VETH"

echo ""
echo "UE1:"
echo "  IP:           $UE1_IP"
echo "  TEID:         $TEID1_DEC"
echo "  Priority:     HIGH"
echo "  Rate Limit:   20mbit"

echo ""
echo "UE2:"
echo "  IP:           $UE2_IP"
echo "  TEID:         $TEID2_DEC"
echo "  Priority:     LOW"
echo "  Rate Limit:   5mbit"

echo ""
echo "=========================================="
echo "Test commands"
echo "=========================================="

echo ""
echo "UE1 traffic:"
echo "docker exec ueransim iperf3 -c iperf-server-1 -u -b 100M -t 5 --bind-dev uesimtun0"

echo ""
echo "UE2 traffic:"
echo "docker exec ueransim iperf3 -c iperf-server-2 -u -b 100M -t 5 --bind-dev uesimtun1"

echo ""
echo "View tc classes:"
echo "sudo tc class show dev $VETH"

echo ""
echo "View tc statistics:"
echo "sudo tc -s class show dev $VETH"

echo ""
echo "View eBPF stats:"
echo "sudo bpftool map dump name stats_map"

echo ""
echo "Drop UE2:"
echo "sudo ./ebpf-qos/qos_manager.py policy --teid $TEID2_DEC --action 1"

echo ""
echo "=========================================="