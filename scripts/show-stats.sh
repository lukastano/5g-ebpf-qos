#!/bin/bash
# show-stats.sh - Display eBPF statistics

if [ ! -f /tmp/qos_state.env ]; then
    echo "ERROR: System not running!"
    exit 1
fi

source /tmp/qos_state.env

echo "eBPF QoS Statistics"
echo "=========================================="
echo ""
echo "Configuration:"
echo "  Interface: $VETH"
echo "  TEID:      $TEID"
echo "  UE IP:     $UE_IP"
echo ""

cd ebpf-qos
sudo ./qos_manager.py stats
echo ""
sudo ./qos_manager.py policies
