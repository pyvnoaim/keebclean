#!/bin/sh
# keebclean installer: downloads the latest release, checks it, and sets up password-free locking.
#   curl -fsSL https://raw.githubusercontent.com/pyvnoaim/keebclean/main/install.sh | sh
set -eu

base=https://github.com/pyvnoaim/keebclean/releases/latest/download
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

echo "downloading keebclean..."
curl -fsSLO "$base/keebclean-macos-universal.tar.gz"
curl -fsSLO "$base/checksums.txt"
shasum -a 256 -c checksums.txt >/dev/null || { echo "checksum mismatch, aborting" >&2; exit 1; }
tar -xzf keebclean-macos-universal.tar.gz

# sudo reads the password from the terminal, so this works even when piped into sh
./keebclean --install < /dev/tty
echo "done: run keebclean to lock your keyboard and trackpad"
