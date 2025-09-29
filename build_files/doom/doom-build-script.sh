#!/usr/bin/env bash
set -xeuo pipefail

# Allow pinning via build args or repo secrets (optional)
: "${DOOMEMACS_REPO:=https://github.com/doomemacs/doomemacs.git}"
: "${DOOMEMACS_REF:=master}"
: "${DOOMDIR_REPO:=https://github.com/ii/doom-config.git}"
: "${DOOMDIR_REF:=canon}"

DOOMDIR_REPO="$DOOMDIR_REPO" \
DOOMDIR_REF="$DOOMDIR_REF" \
DOOMEMACS_REPO="$DOOMEMACS_REPO" \
DOOMEMACS_REF="$DOOMEMACS_REF" \
CACHE_HOME="/var/cache/doom"
DOOM_SEED="/usr/share/doom-seed.zst"

echo "[doom] install firstboot script and service"
install -d -m 0755 /usr/libexec/doom
install -m 0755 /ctx/doom/doom-firstboot.sh      /usr/libexec/doom/doom-firstboot.sh
install -m 0644 /ctx/doom/doom-firstboot.service /etc/systemd/system/doom-firstboot.service
systemctl enable doom-firstboot.service || true

echo "[doom] create emacs / doom cache"
# Check out emacs into our build context
if [ ! -d "$CACHE_HOME/.config/emacs" ]; then
    install -d -m 0755 "$CACHE_HOME/.config" "$CACHE_HOME/.local"

    # Clone doomemacs + doomdir (shallow, stripped of .git)
    git clone --filter=blob:none --depth=1 --branch "$DOOMEMACS_REF" "$DOOMEMACS_REPO" "$CACHE_HOME/.config/emacs"
    # rm -rf "$CACHE_HOME/.config/emacs/.git"

    git clone --filter=blob:none --depth=1 --branch "$DOOMDIR_REF" "$DOOMDIR_REPO" "$CACHE_HOME/.config/doom"
    # rm -rf "$CACHE_HOME/.config/doom/.git"

    # Build template caches
    export HOME="$CACHE_HOME"
    export PATH="$CACHE_HOME/.config/emacs/bin:$PATH"
    cd $HOME
    doom sync --jobs "$(nproc)"
    # Optionally: doom build -y  # warm extra grammars
fi

if [ ! -f "$CACHE_HOME/doom-seed.zst" ]; then
    # Pack the template (configs + straight/native caches)
    tar --zstd -C "$CACHE_HOME" -cpf "$CACHE_HOME/doom-seed.zst" \
        .config/emacs \
        .config/doom \
        .local
fi

cp $CACHE_HOME/doom-seed.zst $DOOM_SEED

ls -la $DOOM_SEED
file $DOOM_SEED
# sleep infinity || true
# 
