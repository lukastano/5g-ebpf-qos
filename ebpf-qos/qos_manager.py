#!/usr/bin/env python3
import subprocess
import sys
import argparse

class GTPQoSManager:
    def __init__(self, interface="enp0s3"):
        self.interface = interface
        self.bpf_obj = "gtp_qos.bpf.o"

    def setup_htb(self):
        print(f"[*] Setting up HTB qdisc...")
        subprocess.run(
            ["sudo", "tc", "qdisc", "del", "dev", self.interface, "root"],
            stderr=subprocess.DEVNULL
        )

        result = subprocess.run(
            ["sudo", "tc", "qdisc", "add", "dev", self.interface, "root",
             "handle", "1:", "htb", "default", "999", "r2q", "100"],
            capture_output=True
        )

        if result.returncode != 0:
            print(result.stderr.decode())
            return False

        subprocess.run(
            ["sudo", "tc", "class", "add", "dev", self.interface, "parent",
             "1:", "classid", "1:1", "htb", "rate", "1000mbit", "ceil", "1000mbit"]
        )

        subprocess.run(
            ["sudo", "tc", "class", "add", "dev", self.interface, "parent",
             "1:1", "classid", "1:999", "htb", "rate", "1000mbit", "ceil", "1000mbit",
             "prio", "7"]
        )

        print("[✓] HTB qdisc ready")
        return True

    def create_rate_class(self, teid, rate_mbit, priority):        
        minor = teid % 60000 + 10
        classid = f"1:{minor}"
        result = subprocess.run(
            ["sudo", "tc", "class", "replace", "dev", self.interface, 
             "parent", "1:1", "classid", classid, "htb", 
             "rate", f"{rate_mbit}mbit", "ceil", f"{rate_mbit}mbit",
             "prio", str(priority)],
            capture_output=True
        )
        if result.returncode != 0:
            print(result.stderr.decode())
            return None
        
        subprocess.run(["sudo", "tc", "filter", "add", "dev", self.interface, 
                        "protocol", "ip", "parent", "1:", "handle", str(minor), 
                        "fw", "flowid", classid])
        return minor

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
            ["sudo", "tc", "filter", "add", "dev", self.interface, "egress",
             "bpf", "da", "obj", self.bpf_obj, "sec", "tc"],
            capture_output=True
        )
        
        if result.returncode != 0:
            print(f"[!] Failed to attach eBPF: {result.stderr.decode()}")
            return False

        self.setup_htb()
        
        print("[✓] eBPF program loaded successfully!")
        return True

    def set_policy(self, teid, action, priority=1, rate=10):
        print(f"[*] Setting policy for TEID {teid}: action={action}")
        
        class_minor = self.create_rate_class(teid, rate, priority)
        if class_minor is None:
            return False

        result = subprocess.run(
            ["sudo", "bpftool", "map", "update",
             "name", "qos_policy_map",
             "key", str(teid), "0", "0", "0",
             "value", str(action), "0", "0", "0",
                    str(priority), "0", "0", "0",
                    str(class_minor), "0", "0", "0"],
            capture_output=True
        )
        
        if result.returncode != 0:
            print(f"[!] Failed: {result.stderr.decode()}")
            return False
        
        actions = ['ALLOW', 'DROP']
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
        subprocess.run(
            ["sudo", "tc", "qdisc", "del", "dev", self.interface, "root"],
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
    parser.add_argument('--action', type=int, choices=[0, 1])
    parser.add_argument('--priority', type=int, default=1)
    parser.add_argument('--rate', type=int, default=10)
    parser.add_argument('--interface', default='enp0s3')
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
        mgr.set_policy(args.teid, args.action, args.priority, args.rate)
    elif args.command == 'stats':
        mgr.get_stats()
    elif args.command == 'policies':
        mgr.show_policies()
    elif args.command == 'watch':
        mgr.watch_logs(args.duration)

if __name__ == "__main__":
    main()
