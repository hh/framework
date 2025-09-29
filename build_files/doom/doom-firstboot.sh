#!/usr/bin/env bash
set -euo pipefail
SEED="/usr/share/doom-seed.zst"
[ -f "$SEED" ] || exit 0
LOCK="/var/lib/doom-firstboot.done"
[ -e "$LOCK" ] && exit 0
USER="$(getent passwd 1000 | cut -d: -f1 || true)"
[ -n "$USER" ] || exit 0
HOME_DIR="$(getent passwd "$USER" | cut -d: -f6)"

mkdir -p "$HOME_DIR"
tar --zstd -xpf "$SEED" -C "$HOME_DIR"
chown -R "$USER:$USER" "$HOME_DIR/.config" "$HOME_DIR/.local"

sudo -u "$USER" bash -lc '
  set -e
  export PATH="$HOME/.config/emacs/bin:$PATH"
  doom sync --force -b
'

touch /var/lib/doom-firstboot.done
