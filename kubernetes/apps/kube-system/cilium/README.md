router bgp 64513
  bgp router-id 172.16.0.1
  no bgp ebgp-requires-policy

  neighbor k8s peer-group
  neighbor k8s remote-as 64514

  neighbor 172.16.0.51 peer-group k8s
  neighbor 172.16.0.52 peer-group k8s
  neighbor 172.16.0.53 peer-group k8s
  neighbor 172.16.0.54 peer-group k8s
  neighbor 172.16.0.55 peer-group k8s
  neighbor 172.16.0.56 peer-group k8s
  neighbor 172.16.0.57 peer-group k8s

  address-family ipv4 unicast
    neighbor k8s next-hop-self
    neighbor k8s soft-reconfiguration inbound
  exit-address-family
exit