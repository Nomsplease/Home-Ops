# RouterOS NPTv6 (RFC 6296-style 1:1 prefix translation) between the stable
# Kubernetes VLAN ULA pool (fdf5:f5ad:9a2a:120::/64, see networking.yaml's
# CiliumLoadBalancerIPPool) and the dynamically-delegated ISP IPv6 prefix.
# Lets Cilium LB-IPAM IPv6 addresses stay reachable from the internet across
# ISP renumbering — Cilium/BGP only ever see the stable ULA side; only the
# rules below need to track the live delegation.
#
# Requires: one downstream interface/VLAN reserved purely to hold a /64 taken
# from the DHCPv6-PD pool (via "from-pool=<pd-pool-name>"), not otherwise used
# for hosts. Its currently-assigned /64 is the moving "PD-slice" side of the
# mapping below. Fill in before applying:
#   <pd-pool-name>     the /ipv6 pool backing your DHCPv6-PD client
#   <pd-slice-iface>   the reserved interface drawing a /64 from that pool

:global k8sLbStablePrefix "fdf5:f5ad:9a2a:120::/64"

/ipv6 firewall nat
add chain=dstnat action=netmap dst-address=0::/64 to-addresses=$k8sLbStablePrefix \
    comment="k8s LB-IPAM NPTv6 inbound (dst-address rewritten by on-pd-renew script)" \
    disabled=yes
add chain=srcnat action=netmap src-address=$k8sLbStablePrefix to-addresses=0::/64 \
    comment="k8s LB-IPAM NPTv6 outbound (to-addresses rewritten by on-pd-renew script)" \
    disabled=yes

# Run once to populate the rules above, then again on every PD renewal
# (hang this off the DHCPv6-PD client's bound/renew script, or a scheduler
# polling every few minutes — whichever this RouterOS version supports more
# reliably for /ipv6 dhcp-client). Re-reading the reserved interface's live
# address avoids any bit-arithmetic on the raw delegated prefix.
:local pdSlice [/ipv6 address get [find interface="<pd-slice-iface>" disabled=no] address]
:local pdSlicePrefix ([:pick $pdSlice 0 [:find $pdSlice "/"]] . "/64")

:if ([:len $pdSlice] > 0) do={
    /ipv6 firewall nat set [find comment~"k8s LB-IPAM NPTv6 inbound"] dst-address=$pdSlicePrefix disabled=no
    /ipv6 firewall nat set [find comment~"k8s LB-IPAM NPTv6 outbound"] to-addresses=$pdSlicePrefix disabled=no
} else={
    :log warning "k8s LB-IPAM NPTv6: no address found on <pd-slice-iface>, leaving rules disabled"
}
