set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
default:
    just -l ansible

[doc('Install/update required Ansible collections')]
[script]
bootstrap:
    ansible-galaxy collection install -r "{{ source_directory() }}/requirements.yml"

[doc('Dry-run a playbook against a host (or all) without changing anything')]
[script]
check playbook="" host="all":
    if [ -z "{{ playbook }}" ]; then
        available="$(ls "{{ source_directory() }}/playbooks" | sed 's/\.yml$//' | paste -sd, -)"
        just log error "No playbook given" "available" "$available"
        exit 1
    fi
    export ANSIBLE_USER="$(op read "op://Kubernetes/FCOS User/Local User/FCOS Username")"
    export SECRET_DOMAIN="$(op read op://Kubernetes/domains/SECRET_DOMAIN)"
    cd "{{ source_directory() }}" && ansible-playbook "playbooks/{{ playbook }}.yml" --limit "{{ host }}" --check --diff

[doc('Apply a playbook to a host (or all matching hosts)')]
[script]
apply playbook="" host="all":
    if [ -z "{{ playbook }}" ]; then
        available="$(ls "{{ source_directory() }}/playbooks" | sed 's/\.yml$//' | paste -sd, -)"
        just log error "No playbook given" "available" "$available"
        exit 1
    fi
    export ANSIBLE_USER="$(op read "op://Kubernetes/FCOS User/Local User/FCOS Username")"
    export SECRET_DOMAIN="$(op read op://Kubernetes/domains/SECRET_DOMAIN)"
    cd "{{ source_directory() }}" && ansible-playbook "playbooks/{{ playbook }}.yml" --limit "{{ host }}"

[confirm('Repoint every control-plane kubeconfig at the apiserver VIP? Only do this once the cluster + Cilium BGP are confirmed healthy. [y|N]')]
[doc('Repoint control-plane kubeconfigs (admin/super-admin/kubelet/controller-manager/scheduler) from the bootstrap node IP to the BGP-advertised VIP')]
[script]
repoint-vip host="all":
    export ANSIBLE_USER="$(op read "op://Kubernetes/FCOS User/Local User/FCOS Username")"
    export SECRET_DOMAIN="$(op read op://Kubernetes/domains/SECRET_DOMAIN)"
    cd "{{ source_directory() }}" && ansible-playbook playbooks/kubernetes.yml --limit "{{ host }}" --tags repoint-vip
