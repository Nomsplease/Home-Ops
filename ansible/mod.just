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

[doc('Dry-run the playbook against a host (or all) without changing anything')]
[script]
check host="all":
    export ANSIBLE_USER="$(op read "op://Kubernetes/FCOS User/Local User/FCOS Username")"
    cd "{{ source_directory() }}" && ansible-playbook playbooks/site.yml --limit "{{ host }}" --check --diff

[doc('Apply the playbook to a host (or all k8s nodes)')]
[script]
apply host="all":
    export ANSIBLE_USER="$(op read "op://Kubernetes/FCOS User/Local User/FCOS Username")"
    cd "{{ source_directory() }}" && ansible-playbook playbooks/site.yml --limit "{{ host }}"
