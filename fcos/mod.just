set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

image := "git.noms.tv/homelab/fcos-bootc"

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

[doc('Download and customize (once) the generic Fedora CoreOS live ISO -- adds our SSH key to its ephemeral `core` user so `install` can drive it remotely. Reused as-is for every node; delete fcos/output to pick up a rotated key.')]
[script]
live-iso:
    mkdir -p "{{ source_directory() }}/output" "{{ source_directory() }}/.build"
    iso="{{ source_directory() }}/output/fedora-coreos-live.iso"
    if [ -f "$iso" ]; then
        just log info "Customized live ISO already cached" "path" "$iso"
        exit 0
    fi
    base_iso="{{ source_directory() }}/.build/fedora-coreos-live-base.iso"
    meta="$(curl -fsSL https://builds.coreos.fedoraproject.org/streams/stable.json)"
    url="$(jq -r '.architectures.x86_64.artifacts.metal.formats.iso.disk.location' <<< "$meta")"
    sha256="$(jq -r '.architectures.x86_64.artifacts.metal.formats.iso.disk.sha256' <<< "$meta")"
    curl -fL --retry 5 --retry-delay 5 --retry-all-errors --progress-bar -o "$base_iso" "$url"
    echo "$sha256  $base_iso" | sha256sum -c -
    sshkey="$(op read "op://Kubernetes/FCOS User/public key")"
    ignition="{{ source_directory() }}/.build/live.ign"
    printf '{"ignition":{"version":"3.4.0"},"passwd":{"users":[{"name":"core","sshAuthorizedKeys":["%s"]}]}}' "$sshkey" > "$ignition"
    podman run --rm \
        -v "{{ source_directory() }}/output:/output" \
        -v "$base_iso:/base.iso:ro" \
        -v "$ignition:/live.ign:ro" \
        quay.io/coreos/coreos-installer:release \
        iso customize --live-ignition /live.ign -o /output/fedora-coreos-live.iso /base.iso
    just log info "Customized live ISO ready -- mount this as virtual media on the node's BMC and boot from it" "path" "$iso"

[doc('Build and remotely install the bootc image on a node already booted into the customized live ISO (see live-iso)')]
[script]
install node tag=`just fcos next-tag`:
    tag="{{ tag }}"
    disk_file="{{ source_directory() }}/nodes/{{ node }}.disk"
    if [ -f "$disk_file" ]; then
        disk="/dev/disk/by-id/$(cat "$disk_file")"
    else
        just log fatal "No $disk_file"
    fi
    just fcos build "$tag"
    mkdir -p "{{ source_directory() }}/.build"
    tarball="{{ source_directory() }}/.build/{{ node }}-bootc-$tag.tar"
    rm -f "$tarball"
    podman save -o "$tarball" "{{ image }}:$tag"
    name="$(basename "$tarball")"
    ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o IdentitiesOnly=yes)
    just log info "Sending image to {{ node }}'s live environment" "host" "{{ node }}"
    scp "${ssh_opts[@]}" -i <(op read "op://Kubernetes/FCOS User/public key") "$tarball" "core@{{ node }}:$name"
    just log info "Loading and installing on {{ node }} (uses your ssh-agent)"
    ssh "${ssh_opts[@]}" -i <(op read "op://Kubernetes/FCOS User/public key") "core@{{ node }}" "\
        sudo podman load -i $name && \
        sudo podman run --rm --privileged --pid=host -v /dev:/dev -v /var/lib/containers/storage:/var/lib/containers/storage --security-opt label=type:unconfined_t {{ image }}:$tag bootc install to-disk --source-imgref containers-storage:{{ image }}:$tag --filesystem ext4 --karg systemd.hostname={{ node }} --wipe $disk && \
        sudo systemctl reboot"
    just log info "{{ node }} is rebooting into the installed OS"

[private]
[script]
remote node cmd:
    username="$(op read "op://Kubernetes/FCOS User/Local User/FCOS Username")"
    ssh -o IdentitiesOnly=yes -i <(op read "op://Kubernetes/FCOS User/public key") "$username@{{ node }}" "{{ cmd }}"

[confirm('Upgrade bootc image on ' + node + ' [y|N] ?')]
[doc('Pull the latest image and reboot a node into it')]
upgrade node tag=`just fcos current-tag`:
    just fcos remote "{{ node }}" "sudo bootc switch {{ image }}:{{ tag }} && sudo systemctl reboot"

[confirm('Roll back bootc image on ' + node + ' [y|N] ?')]
[doc('Roll back a node to its previous deployment')]
rollback node:
    just fcos remote "{{ node }}" "sudo bootc rollback && sudo systemctl reboot"

[doc('Show the current/rollback bootc deployments on a node')]
status node:
    just fcos remote "{{ node }}" "sudo bootc status"
