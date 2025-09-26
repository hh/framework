export image_name := env("IMAGE_NAME", "image-template") # output image name, usually same as repo name, change as needed
export default_tag := env("DEFAULT_TAG", "latest")
export bib_image := env("BIB_IMAGE", "quay.io/centos-bootc/bootc-image-builder:latest")

alias build-vm := build-qcow2
alias rebuild-vm := rebuild-qcow2
alias run-vm := run-vm-qcow2

[private]
default:
    @just --list

# Check Just Syntax
[group('Just')]
check:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt --check -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt --check -f Justfile

# Fix Just Syntax
[group('Just')]
fix:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt -f Justfile || { exit 1; }

# Clean Repo
[group('Utility')]
clean:
    #!/usr/bin/bash
    set -eoux pipefail
    touch _build
    find *_build* -exec rm -rf {} \;
    rm -f previous.manifest.json
    rm -f changelog.md
    rm -f output.env
    rm -f output/

# Sudo Clean Repo
[group('Utility')]
[private]
sudo-clean:
    just sudoif just clean

# sudoif bash function
[group('Utility')]
[private]
sudoif command *args:
    #!/usr/bin/bash
    function sudoif(){
        if [[ "${UID}" -eq 0 ]]; then
            "$@"
        elif [[ "$(command -v sudo)" && -n "${SSH_ASKPASS:-}" ]] && [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
            /usr/bin/sudo --askpass "$@" || exit 1
        elif [[ "$(command -v sudo)" ]]; then
            /usr/bin/sudo "$@" || exit 1
        else
            exit 1
        fi
    }
    sudoif {{ command }} {{ args }}

# This Justfile recipe builds a container image using Podman.
#
# Arguments:
#   $target_image - The tag you want to apply to the image (default: $image_name).
#   $tag - The tag for the image (default: $default_tag).
#
# The script constructs the version string using the tag and the current date.
# If the git working directory is clean, it also includes the short SHA of the current HEAD.
#
# just build $target_image $tag
#
# Example usage:
#   just build aurora lts
#
# This will build an image 'aurora:lts' with DX and GDX enabled.
#

# Build the image using the specified parameters
build $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash

    BUILD_ARGS=()
    if [[ -z "$(git status -s)" ]]; then
        BUILD_ARGS+=("--build-arg" "SHA_HEAD_SHORT=$(git rev-parse --short HEAD)")
    fi

    podman build \
        "${BUILD_ARGS[@]}" \
        --pull=newer \
        --tag "${target_image}:${tag}" \
        .

# Command: _rootful_load_image
# Description: This script checks if the current user is root or running under sudo. If not, it attempts to resolve the image tag using podman inspect.
#              If the image is found, it loads it into rootful podman. If the image is not found, it pulls it from the repository.
#
# Parameters:
#   $target_image - The name of the target image to be loaded or pulled.
#   $tag - The tag of the target image to be loaded or pulled. Default is 'default_tag'.
#
# Example usage:
#   _rootful_load_image my_image latest
#
# Steps:
# 1. Check if the script is already running as root or under sudo.
# 2. Check if target image is in the non-root podman container storage)
# 3. If the image is found, load it into rootful podman using podman scp.
# 4. If the image is not found, pull it from the remote repository into reootful podman.

_rootful_load_image $target_image=image_name $tag=default_tag:
    #!/usr/bin/bash
    set -eoux pipefail

    # Check if already running as root or under sudo
    if [[ -n "${SUDO_USER:-}" || "${UID}" -eq "0" ]]; then
        echo "Already root or running under sudo, no need to load image from user podman."
        exit 0
    fi

    # Try to resolve the image tag using podman inspect
    set +e
    resolved_tag=$(podman inspect -t image "${target_image}:${tag}" | jq -r '.[].RepoTags.[0]')
    return_code=$?
    set -e

    USER_IMG_ID=$(podman images --filter reference="${target_image}:${tag}" --format "'{{ '{{.ID}}' }}'")

    if [[ $return_code -eq 0 ]]; then
        # If the image is found, load it into rootful podman
        ID=$(just sudoif podman images --filter reference="${target_image}:${tag}" --format "'{{ '{{.ID}}' }}'")
        if [[ "$ID" != "$USER_IMG_ID" ]]; then
            # If the image ID is not found or different from user, copy the image from user podman to root podman
            COPYTMP=$(mktemp -p "${PWD}" -d -t _build_podman_scp.XXXXXXXXXX)
            just sudoif TMPDIR=${COPYTMP} podman image scp ${UID}@localhost::"${target_image}:${tag}" root@localhost::"${target_image}:${tag}"
            rm -rf "${COPYTMP}"
        fi
    else
        # If the image is not found, pull it from the repository
        just sudoif podman pull "${target_image}:${tag}"
    fi

# Build a bootc bootable image using Bootc Image Builder (BIB)
# Converts a container image to a bootable image
# Parameters:
#   target_image: The name of the image to build (ex. localhost/fedora)
#   tag: The tag of the image to build (ex. latest)
#   type: The type of image to build (ex. qcow2, raw, iso)
#   config: The configuration file to use for the build (default: disk_config/disk.toml)

# Example: just _rebuild-bib localhost/fedora latest qcow2 disk_config/disk.toml
_build-bib $target_image $tag $type $config: (_rootful_load_image target_image tag)
    #!/usr/bin/env bash
    set -euo pipefail

    args="--type ${type} "
    args+="--use-librepo=True "
    args+="--rootfs=btrfs"

    BUILDTMP=$(mktemp -p "${PWD}" -d -t _build-bib.XXXXXXXXXX)

    sudo podman run \
      --rm \
      -it \
      --privileged \
      --pull=newer \
      --net=host \
      --security-opt label=type:unconfined_t \
      -v $(pwd)/${config}:/config.toml:ro \
      -v $BUILDTMP:/output \
      -v /var/lib/containers/storage:/var/lib/containers/storage \
      "${bib_image}" \
      ${args} \
      "${target_image}:${tag}"

    mkdir -p output
    sudo mv -f $BUILDTMP/* output/
    sudo rmdir $BUILDTMP
    sudo chown -R $USER:$USER output/

# Podman builds the image from the Containerfile and creates a bootable image
# Parameters:
#   target_image: The name of the image to build (ex. localhost/fedora)
#   tag: The tag of the image to build (ex. latest)
#   type: The type of image to build (ex. qcow2, raw, iso)
#   config: The configuration file to use for the build (deafult: disk_config/disk.toml)

# Example: just _rebuild-bib localhost/fedora latest qcow2 disk_config/disk.toml
_rebuild-bib $target_image $tag $type $config: (build target_image tag) && (_build-bib target_image tag type config)

# Build a QCOW2 virtual machine image
[group('Build Virtal Machine Image')]
build-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "qcow2" "disk_config/disk.toml")

# Build a RAW virtual machine image
[group('Build Virtal Machine Image')]
build-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "raw" "disk_config/disk.toml")

# Build an ISO virtual machine image
[group('Build Virtal Machine Image')]
build-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "iso" "disk_config/iso.toml")

# Rebuild a QCOW2 virtual machine image
[group('Build Virtal Machine Image')]
rebuild-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_rebuild-bib target_image tag "qcow2" "disk_config/disk.toml")

# Rebuild a RAW virtual machine image
[group('Build Virtal Machine Image')]
rebuild-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_rebuild-bib target_image tag "raw" "disk_config/disk.toml")

# Rebuild an ISO virtual machine image
[group('Build Virtal Machine Image')]
rebuild-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_rebuild-bib target_image tag "iso" "disk_config/iso.toml")

# Run a virtual machine with the specified image type and configuration
_run-vm $target_image $tag $type $config:
    #!/usr/bin/bash
    set -eoux pipefail

    # Determine the image file based on the type
    image_file="output/${type}/disk.${type}"
    if [[ $type == iso ]]; then
        image_file="output/bootiso/install.iso"
    fi

    # Build the image if it does not exist
    if [[ ! -f "${image_file}" ]]; then
        just "build-${type}" "$target_image" "$tag"
    fi

    # Determine an available port to use
    port=8006
    while grep -q :${port} <<< $(ss -tunalp); do
        port=$(( port + 1 ))
    done
    echo "Using Port: ${port}"
    echo "Connect to http://localhost:${port}"

    # Set up the arguments for running the VM
    run_args=()
    run_args+=(--rm --privileged)
    run_args+=(--pull=newer)
    run_args+=(--publish "127.0.0.1:${port}:8006")
    run_args+=(--env "CPU_CORES=4")
    run_args+=(--env "RAM_SIZE=8G")
    run_args+=(--env "DISK_SIZE=64G")
    run_args+=(--env "TPM=Y")
    run_args+=(--env "GPU=Y")
    run_args+=(--device=/dev/kvm)
    run_args+=(--volume "${PWD}/${image_file}":"/boot.${type}")
    run_args+=(docker.io/qemux/qemu)

    # Run the VM and open the browser to connect
    (sleep 30 && xdg-open http://localhost:"$port") &
    podman run "${run_args[@]}"

# Run a virtual machine from a QCOW2 image
[group('Run Virtal Machine')]
run-vm-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "qcow2" "disk_config/disk.toml")

# Run a virtual machine from a RAW image
[group('Run Virtal Machine')]
run-vm-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "raw" "disk_config/disk.toml")

# Run a virtual machine from an ISO
[group('Run Virtal Machine')]
run-vm-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "iso" "disk_config/iso.toml")

# Run a virtual machine using systemd-vmspawn
[group('Run Virtal Machine')]
spawn-vm rebuild="0" type="qcow2" ram="6G":
    #!/usr/bin/env bash

    set -euo pipefail

    [ "{{ rebuild }}" -eq 1 ] && echo "Rebuilding the ISO" && just build-vm {{ rebuild }} {{ type }}

    systemd-vmspawn \
      -M "bootc-image" \
      --console=gui \
      --cpus=2 \
      --ram=$(echo {{ ram }}| /usr/bin/numfmt --from=iec) \
      --network-user-mode \
      --vsock=false --pass-ssh-key=false \
      -i ./output/**/*.{{ type }}


# Runs shell check on all Bash scripts
lint:
    #!/usr/bin/env bash
    set -eoux pipefail
    # Check if shellcheck is installed
    if ! command -v shellcheck &> /dev/null; then
        echo "shellcheck could not be found. Please install it."
        exit 1
    fi
    # Run shellcheck on all Bash scripts
    /usr/bin/find . -iname "*.sh" -type f -exec shellcheck "{}" ';'

# Runs shfmt on all Bash scripts
format:
    #!/usr/bin/env bash
    set -eoux pipefail
    # Check if shfmt is installed
    if ! command -v shfmt &> /dev/null; then
        echo "shellcheck could not be found. Please install it."
        exit 1
    fi
    # Run shfmt on all Bash scripts
    /usr/bin/find . -iname "*.sh" -type f -exec shfmt --write "{}" ';'

# IMPORT https://github.com/ublue-os/titanoboa/blob/main/Justfile

set unstable := true
PODMAN := which("podman") || require("podman-remote")
workdir := env("TITANOBOA_WORKDIR", "work")
isoroot := env("TITANOBOA_ISO_ROOT", "work/iso-root")
rootfs := workdir/"rootfs"
default_image := "localhost/bbos:latest"
#default_image := "ghcr.io/ublue-os/bluefin:lts"
arch := arch()
### BUILDER CONFIGURATION ###
# Distribution to use for the builder container (for tools and dependencies)
# Supported values: fedora, centos, almalinux
# Set via TITANOBOA_BUILDER_DISTRO environment variable (default: fedora)
builder_distro := env("TITANOBOA_BUILDER_DISTRO", "fedora")
##############################

### HOOKS SCRIPT PATHS ###
# Path to scripts used as hooks in between steps, used in 'hook-*' recipes.
# Must follow the naming convention HOOK_<recipe name without 'hook_' prefix>

# Hook used for custom operations done in the rootfs before it is squashed.
HOOK_post_rootfs := env("HOOK_post_rootfs", "")

# Hook used for custom operations done before the initramfs is generated.
HOOK_pre_initramfs := env("HOOK_pre_initramfs", "")
##########################

### UTILS ###
_ci_grouping := '''
if [[ -n "${CI:-}" ]]; then
    echo "::group::${BASH_SOURCE[0]##*/} step"
    trap 'echo ::endgroup::' EXIT
fi
'''
[private]
just := just_executable() + " -f " + source_file()

[private]
git_root := source_dir()

[private]
builder_image := if builder_distro == "fedora" { "quay.io/fedora/fedora:latest" } else if builder_distro == "centos" { "ghcr.io/hanthor/centos-anaconda-builder:main" } else if builder_distro == "almalinux-kitten" { "quay.io/almalinux/almalinux:10-kitten" } else if builder_distro == "almalinux" { "quay.io/almalinux/almalinux:10" } else { error("Unsupported builder distribution: " + builder_distro + ". Supported: fedora, centos, almalinux") }


[private]
chroot_function := '
function chroot(){
    local command="$1"
    shift
    local args="$*"
    ' + PODMAN + ' run --rm -it \
    --privileged \
    --security-opt label=type:unconfined_t \
    $args \
    --tmpfs /tmp:rw \
    --tmpfs /run:rw \
    --volume ' + git_root + ':/app \
    --rootfs ' + git_root/rootfs + ' \
    /usr/bin/bash -c "$command"
}'

[private]
builder_function := '
function builder(){
    local command="$1"
    shift
    local args="$*"
    ' + PODMAN + ' run --rm -it \
    --privileged \
    --security-opt label=disable \
    --volume ' + git_root + ':/app \
    ' + builder_image + ' \
    /usr/bin/bash -c "$command" $args
}'

[private]
compress_dependencies := '''
function compress_dependencies(){
    local MISSING=()
    local DEPS=(
        mksquashfs
        mkfs.erofs
    )
    for dep in "${DEPS[@]}"; do
        if ! command -v $dep >/dev/null; then
            MISSING+=($dep)
        fi
    done
    echo "${#MISSING[@]}"
}
'''

[private]
iso_dependencies := '
function iso_dependencies(){
    local MISSING=()
    local RPMS=(
        dosfstools
        grub2
        grub2-efi
        grub2-tools
        grub2-tools-extra
        shim
        xorriso
    )
    if [[ "' + arch + '" == "x86_64" ]]; then
        RPMS+=(
            grub2-efi-x64
            grub2-efi-x64-cdboot
            grub2-efi-x64-modules
        )
    elif [[ "' + arch + '" == "aarch64" ]]; then
        RPMS+=(grub2-efi-aa64-modules)
    fi
    if ! command -v rpm >/dev/null; then
        echo "1"
        return
    fi
    for rpm in "${RPMS[@]}"; do
        if ! rpm -q $rpm >/dev/null; then
            MISSING+=($rpm)
        fi
    done
    echo "${#MISSING[@]}"
}'
#############

# Create Directories
init-work:
    @echo "{{ style('command') }}Creating Work Directories...{{ NORMAL }}" >&2
    mkdir -p {{ workdir }}
    mkdir -p {{ isoroot }}
    mkdir -p {{ rootfs }}

# Extract rootfs
rootfs image=default_image:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    set -xeuo pipefail
    # Pull and Extract Filesystem
    # {{ PODMAN }} pull {{ image }} # Pull newer image
    ctr="$({{ PODMAN }} create --rm {{ image }} /usr/bin/bash)" && trap "{{ PODMAN }} rm $ctr" EXIT
    {{ PODMAN }} export $ctr | tar --xattrs-include='*' -p -xf - -C {{ rootfs }}

    # Make /var/tmp be a tmpfs by symlinking to /tmp,
    # in order to make bootc work at runtime.
    rm -rf {{ rootfs }}/var/tmp
    ln -sr {{ rootfs }}/tmp {{ rootfs }}/var/tmp

# Generate initramfs with live modules
initramfs:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ chroot_function }}
    set -euo pipefail
    CMD='set -xeuo pipefail
    dnf install -y dracut-live
    INSTALLED_KERNEL=$(rpm -q kernel-core --queryformat "%{evr}.%{arch}" | tail -n 1)
    mkdir -p $(realpath /root)
    export DRACUT_NO_XATTR=1
    dracut --zstd --reproducible --no-hostonly --kver "$INSTALLED_KERNEL" --add "dmsquash-live dmsquash-live-autooverlay" --force /app/{{ workdir }}/initramfs.img |& grep -v -e "Operation not supported"'
    chroot "$CMD"

# Embed the container
rootfs-include-container container_image=default_image image=default_image:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ chroot_function }}
    set -euo pipefail
    CMD="set -xeuo pipefail
    mkdir -p /var/lib/containers/storage
    podman pull {{ container_image || image }}
    dnf install -y fuse-overlayfs"
    chroot "$CMD"

# Install Flatpaks into the live system
rootfs-include-flatpaks FLATPAKS_FILE="iso_files/system_flatpaks.txt":
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ if FLATPAKS_FILE =~ '(^$|^(?i)\bnone\b$)' { 'exit 0' } else if path_exists(FLATPAKS_FILE) == 'false' { error('Flatpak file inaccessible: ' + FLATPAKS_FILE) } else { '' } }}
    {{ chroot_function }}
    CMD='set -xeuo pipefail
    mkdir -p /var/lib/flatpak
    dnf install -y flatpak

    # Get Flatpaks
    flatpak remote-add --if-not-exists flathub "https://dl.flathub.org/repo/flathub.flatpakrepo"
    grep -v "#.*" /flatpak-list/$(basename {{ FLATPAKS_FILE }}) | sort --reverse | xargs "-i{}" -d "\n" sh -c "flatpak remote-info --arch={{ arch }} --system flathub {} &>/dev/null && flatpak install --noninteractive -y {}" || true'
    set -euo pipefail
    chroot "$CMD" --volume "$(realpath "$(dirname {{ FLATPAKS_FILE }})")":/flatpak-list

# Install polkit rules
rootfs-include-polkit polkit="1":
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ if polkit == "0" { 'exit 0' } else { '' } }}
    set -euo pipefail
    install -D -m 0644 {{ git_root }}/src/polkit-1/rules.d/*.rules -t {{ rootfs }}/etc/polkit-1/rules.d

# Install Livesys Scripts
rootfs-install-livesys-scripts livesys="1":
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ if livesys == "0" { 'exit 0' } else { '' } }}
    {{ chroot_function }}
    set -euo pipefail
    CMD='set -xeuo pipefail
    dnf="$({ which dnf5 || which dnf; } 2>/dev/null)"
    $dnf install -y livesys-scripts

    # Determine desktop environment. Must match one of /usr/libexec/livesys/sessions.d/livesys-{desktop_env}
    desktop_env=""
    _session_file="$(find /usr/share/wayland-sessions/ /usr/share/xsessions \
        -maxdepth 1 -type f -not -name '*gamescope*.desktop' -and -name '*.desktop' -printf '%P' -quit)"
    case $_session_file in
        budgie*) desktop_env=budgie ;;
        cosmic*) desktop_env=cosmic ;;
        gnome*)  desktop_env=gnome  ;;
        plasma*) desktop_env=kde    ;;
        sway*)   desktop_env=sway   ;;
        xfce*)   desktop_env=xfce   ;;
        *) echo "\
           {{ style('error') }}ERROR[rootfs-install-livesys-scripts]{{ NORMAL }}\
           : No Livesys Environment Found"; exit 1 ;;
    esac && unset -v _session_file
    sed -i "s/^livesys_session=.*/livesys_session=${desktop_env}/" /etc/sysconfig/livesys

    # Enable services
    systemctl enable livesys.service livesys-late.service

    # Set default time zone to prevent oddities with KDE clock
    echo "C /var/lib/livesys/livesys-session-extra 0755 root root - /usr/share/factory/var/lib/livesys/livesys-session-extra" > \
      /usr/lib/tmpfiles.d/livesys-session-extra.conf'
    chroot "$CMD"
    install -D -m 0644 {{ git_root }}/src/livesys-session-extra {{ rootfs }}/usr/share/factory/var/lib/livesys/livesys-session-extra

# Hook used for custom operations done in the rootfs before it is squashed.
# Meant to be used in a GH action.
hook-post-rootfs hook=HOOK_post_rootfs:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ if hook == '' { 'exit 0' } else { '' } }}
    {{ chroot_function }}
    set -euo pipefail
    chroot "$(cat '{{ hook }}')"

# Hook used for custom operations done before the initramfs is generated.
# Meant to be used in a GH action.
hook-pre-initramfs hook=HOOK_pre_initramfs:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ if hook == '' { 'exit 0' } else { '' } }}
    {{ chroot_function }}
    set -euo pipefail
    chroot "$(cat '{{ hook }}')"

# Remove the sysroot tree
rootfs-clean-sysroot:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ chroot_function }}
    set -euo pipefail
    CMD='set -xeuo pipefail
    if [[ -d /app ]]; then
        rm -rf /sysroot /ostree
        dnf autoremove -y
        dnf clean all -y
    fi'
    chroot "$CMD"

# Fix SELinux Permissions
rootfs-selinux-fix image=default_image:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    set -euo pipefail
    CMD='set -xeuo pipefail
    cd /app/{{ rootfs }}
    setfiles -F -r . /etc/selinux/targeted/contexts/files/file_contexts .
    chcon --user=system_u --recursive .'
    {{ PODMAN }} run --rm -it \
        --volume {{ git_root }}:/app \
        --workdir "/app" \
        --security-opt label=disable \
        --privileged \
        {{ image }} \
        /usr/bin/bash -c "$CMD"
    rmdir {{ rootfs }}/app || true

# Compress rootfs into a compressed image
squash fs_type="squashfs":
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    CMD='{{ if fs_type == "squashfs" { "mksquashfs $0 $1/squashfs.img -all-root -noappend" } else if fs_type == "erofs" { "mkfs.erofs -d0 --quiet --all-root -zlz4hc,6 -Eall-fragments,fragdedupe=inode -C1048576 $1/squashfs.img $0" } else { error(style('error') + "ERROR[squash]" + NORMAL + ": Invalid Compression") } }}'
    {{ compress_dependencies }}
    {{ builder_function }}
    set -euo pipefail
    BUILDER="$(compress_dependencies)"
    if ! (( BUILDER )); then
        bash -c "$CMD" "$(realpath {{ rootfs }})" "$(realpath {{ workdir }})"
    else
        CMD="dnf install -y {{ if fs_type == 'squashfs' { 'squashfs-tools' } else if fs_type == 'erofs' { 'erofs-utils' } else { '' } }} ; $CMD"
        builder "$CMD" "/app/{{ rootfs }}" "/app/{{ workdir }}"
    fi

# Expand grub templace, according to the image os-release.
process-grub-template $extra_kargs="NONE":
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    set -xeuo pipefail
    kargs=()
    IFS=',' read -r -a kargs <<< "$extra_kargs"
    if [[ "$extra_kargs" == "NONE" ]]; then
        kargs=()
    fi

    OS_RELEASE="{{ rootfs }}/usr/lib/os-release"
    TMPL="src/grub.cfg.tmpl"
    DEST="{{ isoroot }}/boot/grub/grub.cfg"
    # TODO figure out a better mechanism
    PRETTY_NAME="$(source "$OS_RELEASE" >/dev/null && echo "${PRETTY_NAME/ (*)}")"
    sed \
        -e "s|@PRETTY_NAME@|${PRETTY_NAME}|g" \
        -e "s|@EXTRA_KARGS@|${kargs[*]}|g" \
        "$TMPL" >"$DEST"

# Prep the environment for the ISO
iso-organize extra_kargs: && (process-grub-template extra_kargs)
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    set -xeuo pipefail
    mkdir -p {{ isoroot }}/boot/grub {{ isoroot }}/LiveOS
    cp {{ rootfs }}/lib/modules/*/vmlinuz {{ isoroot }}/boot
    cp {{ workdir }}/initramfs.img {{ isoroot }}/boot
    # Hardcoded on the dmsquash-live source code unless specified otherwise via kargs
    # https://github.com/dracut-ng/dracut-ng/blob/0ffc61e536d1193cb837917d6a283dd6094cb06d/modules.d/90dmsquash-live/dmsquash-live-root.sh#L23
    {{ if env('CI', '') == '' { 'cp' } else { 'mv' } }} {{ workdir }}/squashfs.img {{ isoroot }}/LiveOS/squashfs.img

# Build the ISO from the compressed image
iso:
    #!/usr/bin/env bash
    {{ _ci_grouping }}
    {{ if env('CI', '') != '' { "echo '" + style('warning') + "In CI - Deleting: "  + rootfs + "...' " + NORMAL +"; rm -rf " + rootfs } else { '' } }}
    {{ iso_dependencies }}
    BUILDER="$(iso_dependencies)"
    CMD='set -xeuo pipefail
    ISOROOT="$0"
    WORKDIR="$1"

    mkdir -p $ISOROOT/EFI/BOOT
    # ARCH_SHORT needs to be uppercase
    ARCH_SHORT="$(echo {{ arch }} | sed 's/x86_64/x64/g' | sed 's/aarch64/aa64/g')"
    ARCH_32="$(echo {{ arch }} | sed 's/x86_64/ia32/g' | sed 's/aarch64/arm/g')"
    if [[ "$(rpm -E %centos)" -ge 10 ]]; then
        cp -avf /boot/efi/EFI/centos/. $ISOROOT/EFI/BOOT
    elif [[ "$(rpm -E %fedora)" -ge 41 ]]; then
        cp -avf /boot/efi/EFI/fedora/. $ISOROOT/EFI/BOOT
    fi
    cp -avf $ISOROOT/boot/grub/grub.cfg $ISOROOT/EFI/BOOT/BOOT.conf
    cp -avf $ISOROOT/boot/grub/grub.cfg $ISOROOT/EFI/BOOT/grub.cfg
    cp -avf /boot/grub*/fonts/unicode.pf2 $ISOROOT/EFI/BOOT/fonts
    cp -avf $ISOROOT/EFI/BOOT/shim${ARCH_SHORT}.efi "$ISOROOT/EFI/BOOT/BOOT${ARCH_SHORT^^}.efi"
    cp -avf $ISOROOT/EFI/BOOT/shim.efi "$ISOROOT/EFI/BOOT/BOOT${ARCH_32}.efi"

    ARCH_GRUB="$(echo {{ arch }} | sed 's/x86_64/i386-pc/g' | sed 's/aarch64/arm64-efi/g')"
    ARCH_OUT="$(echo {{ arch }} | sed 's/x86_64/i386-pc-eltorito/g' | sed 's/aarch64/arm64-efi/g')"
    ARCH_MODULES="$(echo {{ arch }} | sed 's/x86_64/biosdisk/g' | sed 's/aarch64/efi_gop/g')"

    grub2-mkimage -O $ARCH_OUT -d /usr/lib/grub/$ARCH_GRUB -o $ISOROOT/boot/eltorito.img -p /boot/grub iso9660 $ARCH_MODULES
    grub2-mkrescue -o $ISOROOT/../efiboot.img

    EFI_BOOT_MOUNT=$(mktemp -d)
    mount $ISOROOT/../efiboot.img $EFI_BOOT_MOUNT
    cp -r $EFI_BOOT_MOUNT/boot/grub $ISOROOT/boot/
    umount $EFI_BOOT_MOUNT
    rm -rf $EFI_BOOT_MOUNT

    # https://github.com/FyraLabs/katsu/blob/1e26ecf74164c90bc24299a66f8495eb2aef4845/src/builder.rs#L145
    EFI_BOOT_PART=$(mktemp -d)
    fallocate $WORKDIR/efiboot.img -l 25M
    mkfs.msdos -v -n EFI $WORKDIR/efiboot.img
    mount $WORKDIR/efiboot.img $EFI_BOOT_PART
    mkdir -p $EFI_BOOT_PART/EFI/BOOT
    cp -dRvf $ISOROOT/EFI/BOOT/. $EFI_BOOT_PART/EFI/BOOT
    umount $EFI_BOOT_PART

    ARCH_SPECIFIC=()
    if [ "{{ arch }}" == "x86_64" ] ; then
        ARCH_SPECIFIC=("--grub2-mbr" "/usr/lib/grub/i386-pc/boot_hybrid.img")
    fi

    xorrisofs \
        -R \
        -V titanoboa_boot \
        -partition_offset 16 \
        -appended_part_as_gpt \
        -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B \
        $ISOROOT/../efiboot.img \
        -iso_mbr_part_type EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 \
        -c boot.cat --boot-catalog-hide \
        -b boot/eltorito.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --grub2-boot-info \
        -eltorito-alt-boot \
        -e \
        --interval:appended_partition_2:all:: \
        -no-emul-boot \
        -vvvvv \
        -iso-level 3 \
        -o /app/output.iso \
        "${ARCH_SPECIFIC[@]}" \
        $ISOROOT'
    set -euo pipefail
    if ! (( BUILDER )); then
        bash -c "$CMD" "$(realpath {{ isoroot }})" "$(realpath {{ workdir }})"
    else
        {{ if `systemd-detect-virt -c || true` != 'none' { "echo '" + style('error') + "ERROR[iso]" + NORMAL + ": Cannot run in nested containers'; exit 1" } else { '' } }}
        {{ builder_function }}
        CMD="dnf install -y grub2 grub2-efi grub2-tools grub2-tools-extra xorriso shim dosfstools {{ if arch == "x86_64" { 'grub2-efi-x64-modules grub2-efi-x64-cdboot grub2-efi-x64' } else if arch == "aarch64" { 'grub2-efi-aa64-modules' } else { '' } }}; $CMD"
        builder "$CMD" "/app/{{ isoroot }}" "/app/{{ workdir }}"
    fi

# TODO update this recipe parameters. Make it actually usable
[no-exit-message]
[doc('Build a live-iso')]
@build image=default_image livesys="1" flatpaks_file="src/flatpaks.example.txt" compression="squashfs" extra_kargs="NONE" container_image=image polkit="1": \
    checkroot \
    (show-config image livesys flatpaks_file compression extra_kargs container_image polkit) \
    clean \
    init-work \
    (rootfs image) \
    (hook-pre-initramfs HOOK_pre_initramfs) \
    initramfs \
    (rootfs-include-flatpaks flatpaks_file) \
    (rootfs-include-polkit polkit) \
    (rootfs-install-livesys-scripts livesys) \
    (rootfs-include-container container_image image) \
    (hook-post-rootfs HOOK_post_rootfs) \
    rootfs-clean-sysroot \
    (rootfs-selinux-fix image) \
    (ci-delete-image image) \
    (squash compression) \
    (iso-organize extra_kargs) \
    iso
    mv ./output.iso {{ justfile_dir() }} &>/dev/null


@show-config image livesys flatpaks_file compression extra_kargs container_image polkit:
    echo "Using the following configuration:"
    echo "{{ style('warning') }}################################################################################{{ NORMAL }}"
    echo "PODMAN             := {{ PODMAN }}"
    echo "workdir            := {{ workdir }}"
    echo "isoroot            := {{ isoroot }}"
    echo "rootfs             := {{ rootfs }}"
    echo "builder_distro     := {{ builder_distro }}"
    echo "builder_image      := {{ builder_image }}"
    echo "HOOK_post_rootfs   := {{ if HOOK_post_rootfs =~ '(^$|^(?i)\bnone\b$)' { '' } else { canonicalize(HOOK_post_rootfs) } }}"
    echo "HOOK_pre_initramfs := {{ if HOOK_pre_initramfs =~ '(^$|^(?i)\bnone\b$)' { '' } else { canonicalize(HOOK_pre_initramfs) } }}"
    echo "image              := {{ image }}"
    echo "livesys            := {{ livesys }}"
    echo "flatpaks_file      := {{ if flatpaks_file =~ '(^$|^(?i)\bnone\b$)' { '' } else { canonicalize(flatpaks_file) } }}"
    echo "compression        := {{ compression }}"
    echo "extra_kargs        := {{ extra_kargs }}"
    echo "container_image    := {{ container_image || image }}"
    echo "polkit             := {{ polkit }}"
    echo "CI                 := {{ env('CI', '') }}"
    echo "ARCH               := {{ arch }}"
    echo "{{ style('warning') }}################################################################################{{ NORMAL }}"
    sleep 1


[no-exit-message]
@checkroot:
    if [ `id -u` -gt 0 ]; then echo '{{ style("error") }}ERROR[build]{{ NORMAL }}: Must be root to build ISO' >&2 && exit 1; fi

@clean:
    echo "{{ style('command') }}cleaning {{ absolute_path(workdir) }}...{{ NORMAL }}" >&2
    rm -rf {{ absolute_path(workdir) }}

[private]
delete-image image:
    #!/usr/bin/env bash
    set -xeuo pipefail
    {{ PODMAN }} rmi --force "{{ image }}" || :

[private]
ci-delete-image image:
    #!/usr/bin/env bash
    set -xeuo pipefail
    if [[ -n "${CI:-}" ]]; then
        {{ PODMAN }} rmi --force {{ image }} || :
    fi

# Run VM with qemu
vm ISO_FILE *ARGS:
    #!/usr/bin/env bash
    qemu="qemu-system-{{ arch }}"
    if [[ ! $(type -P "$qemu") ]]; then
      qemu="flatpak run --command=$qemu org.virt_manager.virt-manager"
    fi
    $qemu \
        -enable-kvm \
        -M q35 \
        -cpu host \
        -smp $(( $(nproc) / 2 > 0 ? $(nproc) / 2 : 1 )) \
        -m 4G \
        -net nic,model=virtio \
        -net user,hostfwd=tcp::2222-:22 \
        -display gtk,show-cursor=on \
        -boot d \
        -cdrom {{ ISO_FILE }} {{ ARGS }}

# Run VM with a container and web vnc
container-run-vm ISO_FILE:
    #!/usr/bin/env bash
    set -xeuo pipefail
    # Determine an available port to use
    port=8006
    while grep -q :${port} <<< $(ss -tunalp); do
        port=$(( port + 1 ))
    done
    echo "Using Port: ${port}"
    echo "Connect to http://localhost:${port}"

    # Ram Size
    mem_free=$(awk '/MemAvailable/ { printf "%.0f\n", $2/1024/1024 - 1 }' /proc/meminfo)
    ram_size=$(( mem_free > 64 ? mem_free / 2 : (mem_free > 8 ? 8 : (mem_free < 3 ? 3 : mem_free)) ))

    # Set up the arguments for running the VM
    run_args=()
    run_args+=(--rm --privileged)
    run_args+=(--pull=newer)
    run_args+=(--publish "127.0.0.1:${port}:8006")
    run_args+=(--env "CPU_CORES=$(( $(nproc) / 2 > 0 ? $(nproc) / 2 : 1 ))")
    run_args+=(--env "RAM_SIZE=${ram_size}G")
    run_args+=(--env "DISK_SIZE=64G")
    run_args+=(--env "TPM=Y")
    run_args+=(--env "GPU=Y")
    run_args+=(--env "BOOT_MODE=windows_secure")
    run_args+=(--device=/dev/kvm)
    run_args+=(--volume "{{ canonicalize(ISO_FILE) }}":"/boot.iso")
    run_args+=(ghcr.io/qemus/qemu)

    # Run the VM and open the browser to connect
    {{ PODMAN }} run "${run_args[@]}" &
    xdg-open http://localhost:${port}

# Print the absolute of the files relative to the project dir.
[private]
whereis +FILE_PATHS:
    @realpath -e {{ FILE_PATHS }}
