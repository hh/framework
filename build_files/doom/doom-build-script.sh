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

TPL_HOME="/var/lib/doomtpl"

install -d -m 0755 "$TPL_HOME/.config" "$TPL_HOME/.local"
install -d -m 0755 /usr/share/doom-seed

# Clone doomemacs + doomdir (shallow, stripped of .git)
git clone --filter=blob:none --depth=1 --branch "$DOOMEMACS_REF" "$DOOMEMACS_REPO" "$TPL_HOME/.config/emacs"
# rm -rf "$TPL_HOME/.config/emacs/.git"

git clone --filter=blob:none --depth=1 --branch "$DOOMDIR_REF" "$DOOMDIR_REPO" "$TPL_HOME/.config/doom"
# rm -rf "$TPL_HOME/.config/doom/.git"

# Build template caches
export HOME="$TPL_HOME"
export PATH="$TPL_HOME/.config/emacs/bin:$PATH"
cd $HOME
doom sync --jobs "$(nproc)"
# Optionally: doom build -y  # warm extra grammars

# Pack the template (configs + straight/native caches)
tar --zstd -C "$TPL_HOME" -cpf /usr/share/doom-seed/doom-template.tar.zst \
  .config/emacs \
  .config/doom \
  .local

# We don't want this being part of the image
rm -rf "$TPL_HOME"
