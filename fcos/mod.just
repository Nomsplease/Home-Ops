set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

image := "git.noms.tv/homelab/fcos-bootc"
fedora_version := "44"

[private]
default:
    just -l fcos

[doc('Build the bootc image locally, tagged YYYY.MM.N plus latest')]
[script]
build tag=`just fcos next-tag`:
    tag="{{ tag }}"
    if podman image exists "{{ image }}:$tag"; then
        just log info "Image already built, skipping" "tag" "$tag"
        exit 0
    fi
    mkdir -p "{{ source_directory() }}/.build"
    files="{{ source_directory() }}/.build/files"
    secrets="{{ source_directory() }}/.build/secrets"
    rm -rf "$files" "$secrets"
    cp -r "{{ source_directory() }}/files" "$files"
    cp -r "{{ source_directory() }}/secrets" "$secrets"
    trap 'rm -rf "$files" "$secrets"' EXIT
    find "$files" -type f -exec sh -c 'op inject -i "$1" -o "$1.tmp" && mv "$1.tmp" "$1"' _ {} \;
    find "$secrets" -type f -exec sh -c 'op inject -i "$1" -o "$1.tmp" && mv "$1.tmp" "$1"' _ {} \;
    secret_args=()
    for s in "$secrets"/*; do
        secret_args+=(--secret "id=$(basename "$s"),src=$s")
    done
    cd "{{ source_directory() }}" && podman build \
        --network=host \
        "${secret_args[@]}" \
        -t "{{ image }}:$tag" -t "{{ image }}:latest" -f Containerfile .

[private]
[script]
next-tag:
    year_month="$(date -u +%Y.%m)"
    max=-1
    for existing in $(podman images "{{ image }}" --format "{{ "{{" }}.Tag{{ "}}" }}" | grep -E "^${year_month//./\\.}\.[0-9]+$" || true); do
        n="${existing##*.}"
        [ "$n" -gt "$max" ] && max="$n"
    done
    echo "${year_month}.$((max + 1))"

[private]
[script]
current-tag:
    year_month="$(date -u +%Y.%m)"
    max=-1
    for existing in $(podman images "{{ image }}" --format "{{ "{{" }}.Tag{{ "}}" }}" | grep -E "^${year_month//./\\.}\.[0-9]+$" || true); do
        n="${existing##*.}"
        [ "$n" -gt "$max" ] && max="$n"
    done
    if [ "$max" -lt 0 ]; then
        just log fatal "No locally built image found for $year_month -- run 'just fcos build' first"
    fi
    echo "${year_month}.${max}"

[doc('Push a locally built image (and latest) to the registry')]
[script]
push tag=`just fcos current-tag`:
    op read "op://Kubernetes/forgejo-registry-bot/password" | podman login git.noms.tv \
        -u "$(op read "op://Kubernetes/forgejo-registry-bot/username")" --password-stdin
    podman push "{{ image }}:{{ tag }}"
    podman push "{{ image }}:latest"

[doc('Start (if needed) a throwaway local HTTP server serving fcos/.build, so netboot.xyz (inst.ks=) can fetch a rendered kickstart during PXE install')]
[private]
[script]
kickstart-serve:
    if ! podman container exists fcos-kickstart; then
        podman run -d --name fcos-kickstart --restart=always -p 8000:8000 \
            -v "{{ source_directory() }}/.build:/data:ro" \
            docker.io/library/python:3-slim \
            python3 -m http.server 8000 --directory /data
    elif [ "$(podman inspect -f '{{ "{{" }}.State.Running{{ "}}" }}' fcos-kickstart)" != "true" ]; then
        podman start fcos-kickstart
    fi

[doc('Start (if needed) a throwaway local registry so nodes can pull the image during install, before Forgejo exists')]
[private]
[script]
registry-push tag:
    tag="{{ tag }}"
    if ! podman container exists fcos-registry; then
        podman run -d --name fcos-registry --restart=always -p 5000:5000 docker.io/library/registry:2
    elif [ "$(podman inspect -f '{{ "{{" }}.State.Running{{ "}}" }}' fcos-registry)" != "true" ]; then
        podman start fcos-registry
    fi
    podman tag "{{ image }}:$tag" "localhost:5000/fcos-bootc:$tag"
    podman push --tls-verify=false "localhost:5000/fcos-bootc:$tag"

[private]
[script]
workstation-ip:
    ip -4 route get 1.1.1.1 | grep -oP '(?<=src )\S+' | head -1

[doc('Build the image, push it to a throwaway local registry, and render + serve a per-node Anaconda kickstart over HTTP for netboot.xyz (inst.ks=) to fetch. Mirrors the two disks listed in nodes/<node>.disks as a RAID1 boot')]
[script]
install node tag=`just fcos next-tag`:
    tag="{{ tag }}"
    disks_file="{{ source_directory() }}/nodes/{{ node }}.disks"
    if [ ! -f "$disks_file" ]; then
        just log fatal "No $disks_file"
    fi
    mapfile -t disks < "$disks_file"
    if [ "${#disks[@]}" -ne 2 ]; then
        just log fatal "$disks_file must list exactly two disk ids (one per line)"
    fi
    disk1="${disks[0]}"
    disk2="${disks[1]}"
    just fcos build "$tag"
    just fcos registry-push "$tag"
    registry_host="$(just fcos workstation-ip)"
    mkdir -p "{{ source_directory() }}/.build"
    just fcos kickstart-serve
    ks="{{ source_directory() }}/.build/{{ node }}.ks"
    # NOTE: `raid --device=esp|root` and `network --device=link` syntax below
    # matches documented pykickstart usage but hasn't been run against a real
    # Fedora {{ fedora_version }} Anaconda yet -- `ksvalidator` it (see below)
    # and watch the first real install closely.
    ks_lines=(
        "lang en_US.UTF-8"
        "keyboard us"
        "timezone UTC --utc"
        ""
        "network --bootproto=dhcp --device=link --activate --hostname=${node}"
        ""
        "# Only ever touch this node's two boot disks -- never the Ceph OSD NVMe"
        "# or anything else installed in the box."
        "ignoredisk --only-use=/dev/disk/by-id/${disk1},/dev/disk/by-id/${disk2}"
        "zerombr"
        "clearpart --all --initlabel --disklabel=gpt"
        ""
        "part raid.01 --size=1024 --ondisk=/dev/disk/by-id/${disk1}"
        "part raid.02 --size=1024 --ondisk=/dev/disk/by-id/${disk2}"
        "part raid.11 --size=0 --grow --ondisk=/dev/disk/by-id/${disk1}"
        "part raid.12 --size=0 --grow --ondisk=/dev/disk/by-id/${disk2}"
        ""
        "# metadata 1.0 for the ESP (so firmware still reads it as plain FAT32) is"
        "# applied automatically by Anaconda for a RAID1 /boot/efi -- no need to"
        "# ask for it explicitly."
        "raid /boot/efi --fstype=efi --level=RAID1 --device=esp raid.01 raid.02"
        "raid / --fstype=ext4 --level=RAID1 --device=root raid.11 raid.12"
        ""
        "bootloader --boot-drive=/dev/disk/by-id/${disk1}"
        ""
        "rootpw --lock"
        ""
        "%pre"
        "mkdir -p /etc/containers/registries.conf.d"
        "cat > /etc/containers/registries.conf.d/local-insecure.conf <<EOF"
        "[[registry]]"
        "location = \"${registry_host}:5000\""
        "insecure = true"
        "EOF"
        "%end"
        ""
        "ostreecontainer --url=docker://${registry_host}:5000/fcos-bootc:${tag} --no-signature-verification"
        ""
        "# Anaconda only ever registers one EFI NVRAM boot entry (for disk1's"
        "# ESP member) -- without this, disk2 alone can't cold-boot the"
        "# firmware into GRUB if disk1 fails. Mirror the loader it just"
        "# installed onto disk1's ESP as a second boot entry for disk2."
        "%post"
        'EFI_DIR=$(find /boot/efi/EFI -mindepth 1 -maxdepth 1 -type d ! -iname BOOT | head -1)'
        'LOADER=$(find "$EFI_DIR" -maxdepth 1 \( -iname "shim*.efi" -o -iname "grub*.efi" \) 2>/dev/null | head -1)'
        '[ -z "$LOADER" ] && LOADER=$(find /boot/efi/EFI/BOOT -maxdepth 1 -iname "*.efi" 2>/dev/null | head -1)'
        'if [ -z "$LOADER" ]; then'
        '    echo "WARNING: no EFI loader found under /boot/efi -- register disk2'"'"'s boot entry by hand with efibootmgr" >&2'
        'else'
        '    EFI_PATH=$(echo "${LOADER#/boot/efi}" | tr / "\\")'
        "    efibootmgr -c -d /dev/disk/by-id/${disk2} -p 1 -L \"Fedora (mirror)\" -l \"\$EFI_PATH\" || echo \"WARNING: efibootmgr failed to register disk2's boot entry -- register it by hand\" >&2"
        'fi'
        "%end"
        ""
        "reboot"
    )
    printf '%s\n' "${ks_lines[@]}" > "$ks"
    just log info "Validate the kickstart before pointing netboot.xyz at it" "cmd" "podman run --rm -v $ks:/k.ks:ro registry.fedoraproject.org/fedora:{{ fedora_version }} bash -c 'dnf -y -q install pykickstart >/dev/null && ksvalidator /k.ks'"
    ks_url="http://${registry_host}:8000/{{ node }}.ks"
    just log info "Point {{ node }}'s netboot.xyz MAC override at the Fedora {{ fedora_version }} netinstall entry with this kernel arg, then boot it. Anaconda will partition, mirror both disks, and deploy unattended." "inst.ks" "$ks_url"

[private]
[script]
remote node cmd:
    username="$(op read "op://Kubernetes/FCOS User/Local User/FCOS Username")"
    ssh -o IdentitiesOnly=yes -i <(op read "op://Kubernetes/FCOS User/public key") "$username@{{ node }}" "{{ cmd }}"

[confirm('Upgrade bootc image on ' + node + ' [y|N] ?')]
[doc('Refresh the currently-tracked tag (or switch to a specific tag if given) and reboot')]
[script]
upgrade node tag="":
    tag="{{ tag }}"
    if [ -n "$tag" ]; then
        just fcos remote "{{ node }}" "sudo bootc upgrade --apply --tag $tag"
    else
        just fcos remote "{{ node }}" "sudo bootc upgrade --apply"
    fi

[confirm('Point ' + node + ' at a different image reference: ' + ref + ' [y|N] ?')]
[doc('Point a node at a completely different image reference (registry/repo, not just a tag) and reboot -- for routine tag changes use `upgrade` instead')]
change-image node ref:
    just fcos remote "{{ node }}" "sudo bootc switch --apply {{ ref }}"

[confirm('Roll back bootc image on ' + node + ' [y|N] ?')]
[doc('Roll back a node to its previous deployment')]
rollback node:
    just fcos remote "{{ node }}" "sudo bootc rollback --apply"

[doc('Show the current/rollback bootc deployments on a node')]
status node:
    just fcos remote "{{ node }}" "sudo bootc status"
