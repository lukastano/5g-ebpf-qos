# 5G eBPF QoS System

Complete 5G network with real-time traffic control using eBPF.

## Requirements
- Ubuntu 22.04+, 8GB RAM, 20GB disk
- Docker + Docker Compose + eBPF tools

## Quick Start

Install prerequisites:

sudo apt-get update && sudo apt-get install -y docker.io docker-compose clang llvm libbpf-dev linux-tools-generic tcpdump python3-pip && sudo usermod -aG docker $USER && pip3 install pyroute2

(Log out and back in after this)

## Deploy system:
git clone https://github.com/lukastano/5g-ebpf-qos && cd 5g-ebpf-qos && ./scripts/auto-start.sh

## Test DROP policy (blocks all traffic):
./scripts/set-policy.sh DROP && docker exec ueransim ping -I uesimtun0 -c 5 8.8.8.8

## Test ALLOW policy (permits traffic):
./scripts/set-policy.sh ALLOW && docker exec ueransim ping -I uesimtun0 -c 5 8.8.8.8

## Run comprehensive test suite:
./scripts/test-qos.sh

##Stop system:
./scripts/stop.sh

