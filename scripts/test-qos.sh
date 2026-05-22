#!/bin/bash
# test-qos.sh - Comprehensive test suite for 5G eBPF QoS system

set -e

echo "=========================================="
echo "5G eBPF QoS System - Test Suite"
echo "=========================================="
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Helper function to run a test
run_test() {
    local test_name="$1"
    local test_command="$2"
    local expected_result="$3"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -n "Test $TESTS_RUN: $test_name ... "
    
    if eval "$test_command" > /dev/null 2>&1; then
        if [ "$expected_result" = "pass" ]; then
            echo -e "${GREEN}PASS${NC}"
            TESTS_PASSED=$((TESTS_PASSED + 1))
            return 0
        else
            echo -e "${RED}FAIL${NC} (expected failure)"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            return 1
        fi
    else
        if [ "$expected_result" = "fail" ]; then
            echo -e "${GREEN}PASS${NC} (expected failure)"
            TESTS_PASSED=$((TESTS_PASSED + 1))
            return 0
        else
            echo -e "${RED}FAIL${NC}"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            return 1
        fi
    fi
}

# Get current TEID and veth from the system
echo "Detecting system configuration..."
UE_IP=$(docker exec ueransim ip addr show uesimtun0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
if [ -z "$UE_IP" ]; then
    echo -e "${RED}ERROR: UE not registered. Run ./scripts/auto-start.sh first${NC}"
    exit 1
fi

# Detect TEID
docker exec ueransim ping -I uesimtun0 -c 2 8.8.8.8 > /dev/null 2>&1 &
sleep 1
VETH=$(sudo tcpdump -i any -nn port 2152 -c 1 2>&1 | grep -E "veth.*IP.*2152.*2152" | head -1 | awk '{print $2}')
TEID_HEX=$(sudo timeout 5 tcpdump -i $VETH -nn port 2152 -X -c 1 2>&1 | grep "0x0020:" | head -1 | awk '{print $2$3}')
TEID=$((16#${TEID_HEX:0:8}))

echo "  UE IP:  $UE_IP"
echo "  TEID:   $TEID"
echo "  veth:   $VETH"
echo ""

# ============================================
# TEST SUITE
# ============================================

echo "Starting tests..."
echo ""

# Test 1: Docker containers running
echo "=== Infrastructure Tests ==="
run_test "MongoDB container running" "docker ps | grep -q mongodb" "pass"
run_test "AMF container running" "docker ps | grep -q amf" "pass"
run_test "SMF container running" "docker ps | grep -q smf" "pass"
run_test "UPF container running" "docker ps | grep -q upf" "pass"
run_test "UERANSIM container running" "docker ps | grep -q ueransim" "pass"
echo ""

# Test 2: UE connectivity
echo "=== UE Connectivity Tests ==="
run_test "UE has IP address" "test -n '$UE_IP'" "pass"
run_test "UE can ping Internet (baseline)" "docker exec ueransim ping -I uesimtun0 -c 3 -W 5 8.8.8.8" "pass"
echo ""

# Test 3: eBPF program loaded
echo "=== eBPF Tests ==="
run_test "eBPF program loaded" "sudo bpftool prog show | grep -q gtp_qos_filter" "pass"
run_test "eBPF attached to TC" "sudo tc filter show dev $VETH ingress | grep -q gtp_qos" "pass"
run_test "QoS policy map exists" "sudo bpftool map list | grep -q qos_policy_map" "pass"
run_test "Stats map exists" "sudo bpftool map list | grep -q stats_map" "pass"
echo ""

# Test 4: QoS Policy - ALLOW
echo "=== QoS Policy Tests - ALLOW ==="
sudo ./ebpf-qos/qos_manager.py policy --teid $TEID --action 0 > /dev/null 2>&1
sleep 1

run_test "Policy set to ALLOW" "sudo bpftool map dump name qos_policy_map | grep -A1 '\"key\": $TEID' | grep -q '\"value\": 0'" "pass"
run_test "Ping succeeds with ALLOW policy" "docker exec ueransim ping -I uesimtun0 -c 5 -W 2 8.8.8.8" "pass"

# Check packet loss
RESULT=$(docker exec ueransim ping -I uesimtun0 -c 10 -W 2 8.8.8.8 2>&1 | grep "packet loss" | awk '{print $(NF-2)}' | cut -d'%' -f1)
run_test "ALLOW: Packet loss is 0%" "test '$RESULT' = '0'" "pass"
echo ""

# Test 5: QoS Policy - DROP
echo "=== QoS Policy Tests - DROP ==="
sudo ./ebpf-qos/qos_manager.py policy --teid $TEID --action 1 > /dev/null 2>&1
sleep 1

run_test "Policy set to DROP" "sudo bpftool map dump name qos_policy_map | grep -A1 '\"key\": $TEID' | grep -q '\"value\": 1'" "pass"
run_test "Ping fails with DROP policy" "docker exec ueransim ping -I uesimtun0 -c 5 -W 2 8.8.8.8" "fail"

# Check packet loss
RESULT=$(docker exec ueransim ping -I uesimtun0 -c 10 -W 2 8.8.8.8 2>&1 | grep "packet loss" | awk '{print $(NF-2)}' | cut -d'%' -f1)
run_test "DROP: Packet loss is 100%" "test '$RESULT' = '100'" "pass"
echo ""

# Test 6: Policy switching
echo "=== Policy Switching Tests ==="
# Set to ALLOW
sudo ./ebpf-qos/qos_manager.py policy --teid $TEID --action 0 > /dev/null 2>&1
sleep 1
run_test "Switch to ALLOW: Ping works" "docker exec ueransim ping -I uesimtun0 -c 3 -W 2 8.8.8.8" "pass"

# Set to DROP
sudo ./ebpf-qos/qos_manager.py policy --teid $TEID --action 1 > /dev/null 2>&1
sleep 1
run_test "Switch to DROP: Ping fails" "docker exec ueransim ping -I uesimtun0 -c 3 -W 2 8.8.8.8" "fail"

# Set back to ALLOW
sudo ./ebpf-qos/qos_manager.py policy --teid $TEID --action 0 > /dev/null 2>&1
sleep 1
run_test "Switch back to ALLOW: Ping works" "docker exec ueransim ping -I uesimtun0 -c 3 -W 2 8.8.8.8" "pass"
echo ""

# Test 7: Statistics
echo "=== Statistics Tests ==="
# Generate some traffic
docker exec ueransim ping -I uesimtun0 -c 10 8.8.8.8 > /dev/null 2>&1

run_test "Stats map has data for TEID $TEID" "sudo bpftool map dump name stats_map | grep -q '\"key\": $TEID'" "pass"

# Get packet count
PACKET_COUNT=$(sudo bpftool map dump name stats_map | grep -A1 "\"key\": $TEID" | grep "value" | awk '{print $2}')
run_test "Stats map tracks packets (count > 0)" "test $PACKET_COUNT -gt 0" "pass"
echo "  Packets counted: $PACKET_COUNT"
echo ""

# Test 8: MongoDB data
echo "=== Database Tests ==="
run_test "Subscriber exists in MongoDB" "docker exec mongodb mongo free5gc --eval 'db.subscriptionData.authenticationData.authenticationSubscription.findOne({\"ueId\": \"imsi-208930000000003\"})' | grep -q imsi-208930000000003" "pass"
run_test "amData has nssai field" "docker exec mongodb mongo free5gc --eval 'db.subscriptionData.provisionedData.amData.findOne({\"ueId\": \"imsi-208930000000003\"})' | grep -q nssai" "pass"
run_test "smfSelectionSubscriptionData exists" "docker exec mongodb mongo free5gc --eval 'db.subscriptionData.provisionedData.smfSelectionSubscriptionData.findOne({\"ueId\": \"imsi-208930000000003\"})' | grep -q subscribedSnssaiInfos" "pass"
echo ""

# ============================================
# TEST SUMMARY
# ============================================

echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo "Total tests:  $TESTS_RUN"
echo -e "Passed:       ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed:       ${RED}$TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}✗ Some tests failed${NC}"
    exit 1
fi
