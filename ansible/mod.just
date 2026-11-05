set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
default:
    just -l ansible

[doc('Install/update required Ansible collections')]
[script]
workstation:
    ansible-galaxy collection install -r "{{ source_directory() }}/requirements.yml"

[doc('Configure Fedora CoreOS Kubernetes nodes (networking, storage, gpu). Extra args (--limit, --check --diff, ...) are passed through to ansible-playbook')]
[script]
nodes *args:
    export ANSIBLE_USER="$(op read "op://Kubernetes/FCOS User/Local User/FCOS Username")"
    export SECRET_DOMAIN="$(op read op://Kubernetes/domains/SECRET_DOMAIN)"
    cd "{{ source_directory() }}" && ansible-playbook playbooks/nodes.yml {{ args }}

[doc('Provision the kubeadm cluster on the FCOS k8s nodes. Extra args (--limit, --check --diff, ...) are passed through to ansible-playbook')]
[script]
kubernetes *args:
    export ANSIBLE_USER="$(op read "op://Kubernetes/FCOS User/Local User/FCOS Username")"
    export SECRET_DOMAIN="$(op read op://Kubernetes/domains/SECRET_DOMAIN)"
    cd "{{ source_directory() }}" && ansible-playbook playbooks/kubernetes.yml {{ args }}

[confirm('Repoint every control-plane kubeconfig at the apiserver VIP? Only do this once the cluster + Cilium BGP are confirmed healthy. [y|N]')]
[doc('Repoint control-plane kubeconfigs (admin/super-admin/kubelet/controller-manager/scheduler) from the bootstrap node IP to the BGP-advertised VIP. Extra args (--limit, --check --diff, ...) are passed through to ansible-playbook')]
[script]
repoint-vip *args:
    export ANSIBLE_USER="$(op read "op://Kubernetes/FCOS User/Local User/FCOS Username")"
    export SECRET_DOMAIN="$(op read op://Kubernetes/domains/SECRET_DOMAIN)"
    cd "{{ source_directory() }}" && ansible-playbook playbooks/kubernetes.yml --tags repoint-vip {{ args }}

[confirm('Reset the kubeadm cluster? This wipes etcd/certs/CNI state and reboots the node(s) so the cluster can be reprovisioned from scratch. Use --limit to scope to one host. [y|N]')]
[doc('Tear down the kubeadm cluster (kubeadm reset + state cleanup + reboot) so it can be bootstrapped again from scratch. Extra args (--limit, --check --diff, ...) are passed through to ansible-playbook')]
[script]
teardown *args:
    export ANSIBLE_USER="$(op read "op://Kubernetes/FCOS User/Local User/FCOS Username")"
    export SECRET_DOMAIN="$(op read op://Kubernetes/domains/SECRET_DOMAIN)"
    cd "{{ source_directory() }}" && ansible-playbook playbooks/teardown.yml {{ args }}
