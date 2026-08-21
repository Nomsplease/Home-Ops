# RouterOS v7.4+ translation of cilium-bgp.conf (FRR, for the UDM-SE).

/routing bgp instance
set default as=64513 router-id=10.1.20.1

/routing bgp template
add name=k8s local.role=ebgp afi=ip output.nexthop-choice=force-self

/routing bgp connection
add name=k8s-Main-1 remote.address=10.1.20.11/32 remote.as=64514 templates=k8s
add name=k8s-Main-2 remote.address=10.1.20.12/32 remote.as=64514 templates=k8s
add name=k8s-Main-3 remote.address=10.1.20.13/32 remote.as=64514 templates=k8s
add name=k8s-Main-4 remote.address=10.1.20.14/32 remote.as=64514 templates=k8s
add name=k8s-Main-5 remote.address=10.1.20.15/32 remote.as=64514 templates=k8s
add name=k8s-Main-6 remote.address=10.1.20.16/32 remote.as=64514 templates=k8s
add name=k8s-Main-7 remote.address=10.1.20.17/32 remote.as=64514 templates=k8s
add name=k8s-Main-8 remote.address=10.1.20.18/32 remote.as=64514 templates=k8s