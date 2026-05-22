#!/bin/bash
# set-policy.sh - Easily set QoS policy

if [ ! -f /tmp/qos_state.env ]; then
    echo "ERROR: System not running!"
    echo "Start with: ./scripts/auto-start.sh"
    exit 1
fi

source /tmp/qos_state.env

POLICY=$1

if [ -z "$POLICY" ]; then
    echo "Usage: $0 [DROP|ALLOW]"
    echo ""
    echo "Examples:"
    echo "  $0 DROP    # Block all traffic for TEID $TEID"
    echo "  $0 ALLOW   # Allow all traffic for TEID $TEID"
    exit 1
fi

case $POLICY in
    DROP|drop|1)
        ACTION=1
        ACTION_NAME="DROP"
        ;;
    ALLOW|allow|0)
        ACTION=0
        ACTION_NAME="ALLOW"
        ;;
    *)
        echo "ERROR: Invalid policy: $POLICY"
        echo "Use: DROP or ALLOW"
        exit 1
        ;;
esac

cd ebpf-qos
sudo ./qos_manager.py policy --teid $TEID --action $ACTION

echo ""
echo "SUCCESS: Policy Updated: TEID $TEID -> $ACTION_NAME"
echo ""
echo "Test with:"
echo "  docker exec ueransim ping -I uesimtun0 -c 5 8.8.8.8"
echo ""
if [ "$ACTION_NAME" = "DROP" ]; then
    echo "Expected: 100% packet loss (all packets blocked)"
else
    echo "Expected: 0% packet loss (traffic flowing)"
fi
