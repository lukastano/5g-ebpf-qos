#!/bin/bash
# set-policy.sh - Set QoS policy with auto-detected TEID

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <ALLOW|DROP>"
    exit 1
fi

POLICY=$1

# Auto-detect TEID
docker exec ueransim ping -I uesimtun0 -c 2 8.8.8.8 > /dev/null 2>&1 &
sleep 1
VETH=$(sudo tcpdump -i any -nn port 2152 -c 1 2>&1 | grep -E "veth.*IP.*2152.*2152" | head -1 | awk '{print $2}')
TEID_HEX=$(sudo timeout 5 tcpdump -i $VETH -nn port 2152 -X -c 1 2>&1 | grep "0x0020:" | head -1 | awk '{print $2$3}')
TEID=$((16#${TEID_HEX:0:8}))

if [ -z "$TEID" ]; then
    echo "ERROR: Could not detect TEID"
    exit 1
fi

case $POLICY in
    ALLOW|allow|0)
        sudo ./ebpf-qos/qos_manager.py policy --teid $TEID --action 0
        ;;
    DROP|drop|1)
        sudo ./ebpf-qos/qos_manager.py policy --teid $TEID --action 1
        ;;
    *)
        echo "Invalid policy: $POLICY"
        echo "Use: ALLOW or DROP"
        exit 1
        ;;
esac
