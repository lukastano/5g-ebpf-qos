#!/usr/bin/env python3
import subprocess
import sys
import argparse

class GTPQoSManager:
    def __init__(self, interface="enp0s8"):
        self.interface = interface
        self.bpf_obj = "gtp_qos.bpf.o"
        
    def load_bpf_program(self):
        print(f"[*] Loading eBPF program on interface {self.interface}...")
        
        subprocess.run(
            ["sudo", "tc", "qdisc", "del", "dev", self.interface, "clsact"],
            stderr=subprocess.DEVNULL
        )
        
        result = subprocess.run(
            ["sudo", "tc", "qdisc", "add", "dev", self.interface, "clsact"],
            capture_output=True
        )
        
        if result.returncode != 0:
            print(f"[!] Failed to add qdisc: {result.stderr.decode()}")
            return False
        
        result = subprocess.run(
            ["sudo", "tc", "filter", "add", "dev", self.interface, "ingress",
             "bpf", "da", "obj", self.bpf_obj, "sec", "tc"],
            capture_output=True
        )
        
        if result.returncode != 0:
            print(f"[!] Failed to attach eBPF: {result.stderr.decode()}")
            return False
        
        print("[✓] eBPF program loaded successfully!")
        return True
    
    def set_policy(self, teid, action):
        print(f"[*] Setting policy for TEID {teid}: action={action}")
        
        result = subprocess.run(
            ["sudo", "bpftool", "map", "update",
             "name", "qos_policy_map",
             "key", str(teid), "0", "0", "0",
             "value", str(action), "0", "0", "0"],
            capture_output=True
        )
        
        if result.returncode != 0:
            print(f"[!] Failed: {result.stderr.decode()}")
            return False
        
        actions = ['ALLOW', 'DROP', 'RATE_LIMIT']
        print(f"[✓] Policy set: TEID {teid} -> {actions[action]}")
        return True
    
    def get_stats(self):
        print("\n[*] Statistics:")
        print("=" * 60)
        
        result = subprocess.run(
            ["sudo", "bpftool", "map", "dump", "name", "stats_map"],
            capture_output=True, text=True
        )
        
        if result.returncode == 0:
            print(result.stdout if "key:" in result.stdout else "  No traffic yet")
        else:
            print("  Failed to read stats")
        
        print("=" * 60)
    
    def show_policies(self):
        print("\n[*] QoS Policies:")
        print("=" * 60)
        
        result = subprocess.run(
            ["sudo", "bpftool", "map", "dump", "name", "qos_policy_map"],
            capture_output=True, text=True
        )
        
        if result.returncode == 0:
            print(result.stdout if "key:" in result.stdout else "  No policies")
        else:
            print("  Failed to read policies")
        
        print("=" * 60)
    
    def unload_bpf_program(self):
        print("[*] Unloading eBPF program...")
        subprocess.run(
            ["sudo", "tc", "qdisc", "del", "dev", self.interface, "clsact"],
            stderr=subprocess.DEVNULL
        )
        print("[✓] Unloaded")
    
    def watch_logs(self, duration=10):
        print(f"[*] Watching logs for {duration}s...")
        print("=" * 60)
        
        subprocess.run(
            ["sudo", "timeout", str(duration), "cat", "/sys/kernel/debug/tracing/trace_pipe"],
            stderr=subprocess.DEVNULL
        )
        
        print("=" * 60)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['load', 'unload', 'policy', 'stats', 'watch', 'policies'])
    parser.add_argument('--teid', type=int)
    parser.add_argument('--action', type=int, choices=[0, 1, 2])
    parser.add_argument('--interface', default='enp0s8')
    parser.add_argument('--duration', type=int, default=10)
    
    args = parser.parse_args()
    mgr = GTPQoSManager(interface=args.interface)
    
    if args.command == 'load':
        mgr.load_bpf_program()
    elif args.command == 'unload':
        mgr.unload_bpf_program()
    elif args.command == 'policy':
        if not args.teid or args.action is None:
            print("[!] Need --teid and --action")
            sys.exit(1)
        mgr.set_policy(args.teid, args.action)
    elif args.command == 'stats':
        mgr.get_stats()
    elif args.command == 'policies':
        mgr.show_policies()
    elif args.command == 'watch':
        mgr.watch_logs(args.duration)

if __name__ == "__main__":
    main()
