#!/bin/bash
# stop.sh - Stop the entire system

echo "Stopping 5G eBPF QoS System..."

# Unload eBPF
if [ -f /tmp/qos_state.env ]; then
    source /tmp/qos_state.env
    echo "  Unloading eBPF from $VETH..."
    cd ebpf-qos
    sudo ./qos_manager.py unload --interface $VETH 2>/dev/null || true
    cd ..
    rm /tmp/qos_state.env
fi

# Stop Docker
echo "  Stopping Docker containers..."
cd deployment
docker compose down

# Clean up networks
echo "  Cleaning up networks..."
docker network rm deployment_privnet 2>/dev/null || true
docker network rm free5gc-compose_privnet 2>/dev/null || true

cd ..

echo "System stopped successfully"
