router bgp 64513
  bgp router-id 10.1.10.1
  no bgp ebgp-requires-policy

  neighbor k8s peer-group
  neighbor k8s remote-as 64514

  neighbor 10.1.10.51 peer-group k8s
  neighbor 10.1.10.52 peer-group k8s
  neighbor 10.1.10.53 peer-group k8s
  neighbor 10.1.10.54 peer-group k8s
  neighbor 10.1.10.55 peer-group k8s
  neighbor 10.1.10.56 peer-group k8s

  address-family ipv4 unicast
    neighbor k8s next-hop-self
    neighbor k8s soft-reconfiguration inbound
  exit-address-family
exit