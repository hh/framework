#!/bin/bash

set -ouex pipefail

### Install packages

# Packages can be installed from any enabled yum repo on the image.
# RPMfusion repos are available by default in ublue main images
# List of rpmfusion packages can be found here:
# https://mirrors.rpmfusion.org/mirrorlist?path=free/fedora/updates/39/x86_64/repoview/index.html&protocol=https&redirect=1

# this installs a package from fedora repos
dnf5 install -y tmux touchegg xdotools

# Use a COPR Example:
#
# dnf5 -y copr enable ublue-os/staging
# dnf5 -y install package
# Disable COPRs so they don't end up enabled on the final image:
# dnf5 -y copr disable ublue-os/staging

#### Example for enabling a System Unit File
#
rpm-ostree override install touchegg xdotool vim

systemctl enable podman.socket

echo "[doom] layering runtime deps"
rpm-ostree install \
  emacs-gtk+x11 \
  emacs \
  libgccjit \
  git-core \
  ripgrep \
  fd-find \
  gcc \
  gnutls \
  make \
  unzip

echo "[doom] staging files & units"
install -d -m 0755 /usr/libexec/doom
install -d -m 0755 /usr/share/doom-seed

# drop our scripts into the image
install -m 0755 /ctx/doom/doom-build-script.sh   /usr/libexec/doom/doom-build-script.sh
install -m 0755 /ctx/doom/doom-firstboot.sh      /usr/libexec/doom/doom-firstboot.sh
install -m 0644 /ctx/doom/doom-firstboot.service /etc/systemd/system/doom-firstboot.service

echo "[doom] build-time precompile + seed archive"
/usr/libexec/doom/doom-build-script.sh

echo "[doom] enabling first-boot hydrator"
systemctl enable doom-firstboot.service || true

echo "[doom] done"
