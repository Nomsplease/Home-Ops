# RouterOS 7.2.4 translation of cilium-bgp.conf (FRR, for the UDM-SE).

/routing bgp instance
set name=k8s as=64513 router-id=10.1.20.1

/routing bgp template
add name=k8s afi=ip,ipv6 nexthop-choice=force-self

/routing bgp connection
add name=k8s-1 remote.address=10.1.20.11/32 remote.as=64514 local.role=ebgp templates=k8s instance=k8s
add name=k8s-2 remote.address=10.1.20.12/32 remote.as=64514 local.role=ebgp templates=k8s instance=k8s
add name=k8s-3 remote.address=10.1.20.13/32 remote.as=64514 local.role=ebgp templates=k8s instance=k8s