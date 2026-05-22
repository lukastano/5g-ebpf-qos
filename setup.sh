#!/bin/bash
# setup.sh - One-time setup for 5G eBPF QoS System

set -e

echo "Setting up 5G eBPF QoS System..."

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    echo "ERROR: Don't run as root! Run as regular user (sudo will be used when needed)"
    exit 1
fi

# 1. Install dependencies
echo "Installing dependencies..."
sudo apt update
sudo apt install -y \
    docker.io \
    docker-compose \
    clang \
    llvm \
    libbpf-dev \
    linux-headers-$(uname -r) \
    bpftool \
    iproute2 \
    tcpdump \
    jq

# 2. Add user to docker group
echo "Adding $USER to docker group..."
sudo usermod -aG docker $USER

# 3. Check kernel version
KERNEL=$(uname -r)
echo "Kernel version: $KERNEL"
if [[ ! "$KERNEL" =~ 6\.17\.0-23 ]]; then
    echo "WARNING: This system was tested on kernel 6.17.0-23"
    echo "You're running $KERNEL - you may encounter gtp5g module issues"
fi

# 4. Check gtp5g module
echo "Checking gtp5g module..."
if ! lsmod | grep -q gtp5g; then
    echo "WARNING: gtp5g module not loaded. Attempting to load..."
    sudo modprobe gtp5g 2>/dev/null || echo "ERROR: gtp5g not available. UPF may fail."
else
    GTP5G_VER=$(modinfo gtp5g | grep "^version:" | awk '{print $2}')
    echo "SUCCESS: gtp5g module loaded (version: $GTP5G_VER)"
fi

# 5. Set up IP forwarding persistence
echo "Configuring IP forwarding..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
fi
sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null

# 6. Build eBPF program
echo "Building eBPF program..."
cd ebpf-qos
make clean 2>/dev/null || true
make
if [ ! -f gtp_qos.bpf.o ]; then
    echo "ERROR: eBPF build failed!"
    exit 1
fi
cd ..

# 7. Make scripts executable
echo "Making scripts executable..."
chmod +x scripts/*.sh
chmod +x ebpf-qos/qos_manager.py

# 8. Pull Docker images
echo "Pulling Docker images (this may take a few minutes)..."
cd deployment
docker compose pull
cd ..

echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
echo "IMPORTANT: You must log out and log back in for docker"
echo "group membership to take effect!"
echo ""
echo "After logging back in, run:"
echo "  ./scripts/auto-start.sh"
echo ""
