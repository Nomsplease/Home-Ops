set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

image := "git.noms.tv/homelab/fcos-bootc"
apoci_image := "registry.noms.tv/fcos-bootc"
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
    op read "op://Kubernetes/Apoci/PushToken" | podman login registry.noms.tv \
        -u registry --password-stdin
    podman tag "{{ image }}:{{ tag }}" "{{ apoci_image }}:{{ tag }}"
    podman tag "{{ image }}:latest" "{{ apoci_image }}:latest"
    podman push "{{ apoci_image }}:{{ tag }}"
    podman push "{{ apoci_image }}:latest"

[doc('Download (once) and cache the Fedora Server netinstall ISO used as the base for per-node install ISOs')]
[private]
[script]
netinst-iso:
    mkdir -p "{{ source_directory() }}/.build"
    iso="{{ source_directory() }}/.build/fedora-{{ fedora_version }}-netinst.iso"
    if [ -f "$iso" ]; then
        just log info "Base netinstall ISO already cached" "path" "$iso"
        exit 0
    fi
    base_url="https://download.fedoraproject.org/pub/fedora/linux/releases/{{ fedora_version }}/Server/x86_64/iso"
    filename="$(curl -fsSL "$base_url/" | grep -oE 'Fedora-Server-netinst-x86_64-{{ fedora_version }}-[0-9.]+\.iso' | head -1)"
    if [ -z "$filename" ]; then
        just log fatal "Could not find a Fedora {{ fedora_version }} Server netinst ISO at $base_url"
    fi
    point="${filename#Fedora-Server-netinst-x86_64-{{ fedora_version }}-}"
    point="${point%.iso}"
    checksum_file="Fedora-Server-{{ fedora_version }}-${point}-x86_64-CHECKSUM"
    tmp="{{ source_directory() }}/.build/$filename"
    curl -fL --retry 5 --retry-delay 5 --retry-all-errors --progress-bar -o "$tmp" "$base_url/$filename"
    sha256="$(curl -fsSL "$base_url/$checksum_file" | grep -F "($filename)" | awk '{print $4}')"
    if [ -z "$sha256" ]; then
        rm -f "$tmp"
        just log fatal "Could not find a checksum for $filename in $checksum_file"
    fi
    echo "$sha256  $tmp" | sha256sum -c -
    just log info "Patching GRUB default boot entry to skip the 'test this media' pass"
    podman run --rm -v "$tmp:/iso:rw" registry.fedoraproject.org/fedora:{{ fedora_version }} bash -c '
        dnf -y -q install xorriso >/dev/null
        cd /tmp
        xorriso -indev /iso -osirrox on -extract /EFI/BOOT/grub.cfg efi-grub.cfg -extract /EFI/BOOT/BOOT.conf efi-boot.conf -extract /boot/grub2/grub.cfg bios-grub.cfg
        sed -i "s/^set default=\"1\"\$/set default=\"0\"/" efi-grub.cfg efi-boot.conf bios-grub.cfg
        # -boot_image any replay preserves the El Torito boot catalog on write --
        # without it xorriso silently drops it, producing an unbootable ISO.
        xorriso -indev /iso -outdev /iso -boot_image any replay -update efi-grub.cfg /EFI/BOOT/grub.cfg -update efi-boot.conf /EFI/BOOT/BOOT.conf -update bios-grub.cfg /boot/grub2/grub.cfg -- -commit
    '
    mv "$tmp" "$iso"
    just log info "Base netinstall ISO cached" "path" "$iso"

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

[doc('Build the image, push it to a throwaway local registry, and bake a single generic Anaconda kickstart into a bootable Fedora netinstall ISO (mount as BMC virtual media or write to USB) -- the same ISO installs every node. The boot disk is auto-detected by model at install time, so no per-node data is needed')]
[script]
install tag=`just fcos next-tag`:
    tag="{{ tag }}"
    just fcos build "$tag"
    just fcos registry-push "$tag"
    just fcos netinst-iso
    registry_host="$(just fcos workstation-ip)"
    mkdir -p "{{ source_directory() }}/.build" "{{ source_directory() }}/output"
    ks="{{ source_directory() }}/.build/fcos-install.ks"
    # Plain @TOKEN@ substitution, not `just template` -- Jinja's `{#` collides with bash's `${#arr[@]}`.
    sed -e "s|@REGISTRY_HOST@|$registry_host|g" -e "s|@TAG@|$tag|g" \
        "{{ source_directory() }}/install.ks.tmpl" > "$ks"
    just log info "Checking %pre/%post bash syntax"
    awk '/^%pre$/,/^%end$/{if (!/^%pre$/ && !/^%end$/) print}' "$ks" | bash -n
    awk '/^%post$/,/^%end$/{if (!/^%post$/ && !/^%end$/) print}' "$ks" | bash -n
    just log info "Validate the kickstart before baking it into the ISO (the %include target is stubbed empty for this check only -- the real content is generated by %pre at install time)" "cmd" "podman run --rm -v $ks:/k.ks:ro registry.fedoraproject.org/fedora:{{ fedora_version }} bash -c 'dnf -y -q install pykickstart >/dev/null && touch /tmp/part-include.cfg && ksvalidator /k.ks'"
    base_iso="{{ source_directory() }}/.build/fedora-{{ fedora_version }}-netinst.iso"
    out_iso="{{ source_directory() }}/output/fcos-install.iso"
    rm -f "$out_iso"
    # --skip-mkefiboot: rootless podman can't grant the loop-device access it needs.
    podman run --rm \
        -v "$base_iso:/base.iso:ro" \
        -v "$ks:/ks.cfg:ro" \
        -v "{{ source_directory() }}/output:/output" \
        registry.fedoraproject.org/fedora:{{ fedora_version }} \
        bash -c 'dnf -y -q install lorax >/dev/null && mkksiso --skip-mkefiboot /ks.cfg /base.iso /output/fcos-install.iso'
    just log info "Generic install ISO ready -- mount as virtual media on any node's BMC (or write to USB) and boot from it. Anaconda will detect the right boot disk and deploy unattended. Ansible sets the hostname afterward." "path" "$out_iso"

[private]
[script]
remote node cmd:
    username="$(op read "op://Kubernetes/FCOS User/Local User/FCOS Username")"
    ssh -o IdentitiesOnly=yes -i <(op read "op://Kubernetes/FCOS User/public key") "$username@{{ node }}" "{{ cmd }}"

#[confirm('Upgrade bootc image on ' + node + ' [y|N] ?')]
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

[confirm('Build, push to a throwaway local registry, and switch ' + node + ' to pull from this workstation right now [y|N] ?')]
[doc('For emergencies: Build the image, push it to a throwaway local registry on this workstation, and switch a live node straight to it.')]
[script]
change-image-local node tag=`just fcos next-tag`:
    tag="{{ tag }}"
    just fcos build "$tag"
    just fcos registry-push "$tag"
    registry_host="$(just fcos workstation-ip)"
    config_b64="$(printf '[[registry]]\nlocation = "%s:5000"\ninsecure = true\n' "$registry_host" | base64 -w0)"
    just fcos remote "{{ node }}" "echo $config_b64 | base64 -d | sudo tee /etc/containers/registries.conf.d/workstation-emergency.conf >/dev/null"
    just fcos remote "{{ node }}" "sudo bootc switch --apply $registry_host:5000/fcos-bootc:$tag"


[confirm('Roll back bootc image on ' + node + ' [y|N] ?')]
[doc('Roll back a node to its previous deployment')]
rollback node:
    just fcos remote "{{ node }}" "sudo bootc rollback --apply"

[doc('Show the current/rollback bootc deployments on a node')]
status node:
    just fcos remote "{{ node }}" "sudo bootc status"