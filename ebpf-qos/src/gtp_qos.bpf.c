#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/in.h>
#include <linux/udp.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#define ETH_P_IP 0x0800

struct gtpv1_hdr {
    __u8 flags;
    __u8 type;
    __u16 length;
    __u32 teid;
} __attribute__((packed));

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, __u32);
    __type(value, __u32);
} qos_policy_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, __u32);
    __type(value, __u64);
} stats_map SEC(".maps");

SEC("tc")
int gtp_qos_filter(struct __sk_buff *skb)
{
    void *data_end = (void *)(long)skb->data_end;
    void *data = (void *)(long)skb->data;
    
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return TC_ACT_OK;
    
    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return TC_ACT_OK;
    
    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return TC_ACT_OK;
    
    if (ip->protocol != IPPROTO_UDP)
        return TC_ACT_OK;
    
    struct udphdr *udp = (void *)ip + (ip->ihl * 4);
    if ((void *)(udp + 1) > data_end)
        return TC_ACT_OK;
    
    if (udp->dest != bpf_htons(2152))
        return TC_ACT_OK;
    
    struct gtpv1_hdr *gtp = (void *)(udp + 1);
    if ((void *)(gtp + 1) > data_end)
        return TC_ACT_OK;
    
    __u32 teid = bpf_ntohl(gtp->teid);
    
    __u64 init_val = 1;
    __u64 *count = bpf_map_lookup_elem(&stats_map, &teid);
    if (count) {
        __sync_fetch_and_add(count, 1);
    } else {
        bpf_map_update_elem(&stats_map, &teid, &init_val, BPF_ANY);
    }
    
    __u32 *policy = bpf_map_lookup_elem(&qos_policy_map, &teid);
    if (policy && *policy == 1) {
        bpf_printk("GTP QoS: DROP TEID=%u\n", teid);
        return TC_ACT_SHOT;
    }
    
    bpf_printk("GTP packet: TEID=%u\n", teid);
    return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";
