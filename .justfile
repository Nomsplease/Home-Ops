#!/usr/bin/env -S just --justfile

set lazy
set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']

# Bootstrap Recipes
[group: 'Bootstrap']
mod bootstrap "bootstrap"

# Kube Recipes
[group: 'Kube']
mod kube "kubernetes"

# Talos Recipes
[group: 'Talos']
mod talos "talos"

# Fedora CoreOS Recipes
[group: 'FCOS']
mod fcos "fcos"

# Ansible Recipes
[group: 'Ansible']
mod ansible "ansible"

[private]
default:
    just -l

[doc('Install the required workstation tooling for this repo (CachyOS/Arch)')]
deps:
    sudo pacman -Syu --needed gum yq kubectl docker podman ansible talosctl helmfile helm kustomize sops fluxcd
    yay -Syu --needed minijinja-cli-bin 1password-cli

[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}

[private]
template file *args:
    minijinja-cli --env --autoescape=none "{{ file }}" {{ args }} | op inject