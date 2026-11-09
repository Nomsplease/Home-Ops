# RouterOS 7.2.4 translation of cilium-bgp.conf (FRR, for the UDM-SE).

/routing bgp instance
set name=k8s as=64513 router-id=10.1.10.1

/routing bgp template
add name=k8s afi=ip nexthop-choice=force-self

/routing bgp connection
add name=K8S-1 remote.address=10.1.10.6/32 remote.as=64514 local.role=ebgp templates=k8s instance=k8s
add name=K8S-2 remote.address=10.1.10.7/32 remote.as=64514 local.role=ebgp templates=k8s instance=k8s
add name=K8S-3 remote.address=10.1.10.8/32 remote.as=64514 local.role=ebgp templates=k8s instance=k8s