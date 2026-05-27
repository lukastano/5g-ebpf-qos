#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/in.h>
#include <linux/udp.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#define ETH_P_IP 0x0800

#define ACTION_ALLOW        0
#define ACTION_DROP         1

#define MAX_BURST (1024 * 1024)

struct gtpv1_hdr {
    __u8 flags;
    __u8 type;
    __u16 length;
    __u32 teid;
} __attribute__((packed));

struct qos_policy {
    __u32 action;
    __u32 priority;
    __u32 classid;
};

struct stats {
    __u64 packets;
    __u64 bytes;
    __u64 drops;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, __u32);
    __type(value, struct qos_policy);
} qos_policy_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, __u32);
    __type(value, struct stats);
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
    
    // Check BOTH source and destination ports for GTP-U (2152)
    if (udp->dest != bpf_htons(2152) && udp->source != bpf_htons(2152))
        return TC_ACT_OK;
    
    struct gtpv1_hdr *gtp = (void *)(udp + 1);
    if ((void *)(gtp + 1) > data_end)
        return TC_ACT_OK;
    
    __u32 teid = bpf_ntohl(gtp->teid);
    
    // Update stats
    struct stats *s;
    struct stats init_stats = {};

    s = bpf_map_lookup_elem(&stats_map, &teid);
    if (!s) {
        bpf_map_update_elem(&stats_map, &teid, &init_stats, BPF_ANY);
        s = bpf_map_lookup_elem(&stats_map, &teid);
    }
    if (s) {
        __sync_fetch_and_add(&s->packets, 1);
        __sync_fetch_and_add(&s->bytes, skb->len);
    }

    struct qos_policy *policy;
    policy = bpf_map_lookup_elem(&qos_policy_map, &teid);
    if (!policy)
        return TC_ACT_OK;
    switch (policy->action) {
        case ACTION_DROP:
            if (s)
                __sync_fetch_and_add(&s->drops, 1);
            bpf_printk("GTP QoS: DROP TEID=%u\n", teid);
            return TC_ACT_SHOT;
        case ACTION_ALLOW:
            // skb->priority = policy->priority;
            // skb->priority = (1 << 16) | (policy->classid & 0xFFFF);
            skb->mark = policy->classid;
            bpf_printk("GTP QoS: ALLOW TEID=%u priority=%u classid=%u\n", 
                    teid, policy->priority, policy->classid);
            // bpf_printk("GTP QoS: ALLOW TEID=%u -> Mapping to Class 1:%u (Hex: 0x%x)\n", 
            //         teid, policy->classid, skb->priority);
            return TC_ACT_OK;
        default:
            return TC_ACT_OK;
    }
}

char _license[] SEC("license") = "GPL";
