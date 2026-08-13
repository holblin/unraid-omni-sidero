#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY="holblin/unraid-omni-sidero"
BRANCH="${OMNI_INSTALL_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPOSITORY}/${BRANCH}"
TEMPLATE_DIR="${OMNI_TEMPLATE_DIR:-/boot/config/plugins/dockerMan/templates-user}"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)
TEMP_DIR=""

cleanup() {
  [[ -z "$TEMP_DIR" || ! -d "$TEMP_DIR" ]] || rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

download() {
  local url=$1 destination=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$destination"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$destination" "$url"
  else
    die "curl or wget is required"
  fi
}

if [[ -f "$SCRIPT_DIR/setup.sh" && -f "$SCRIPT_DIR/templates/omni.xml" && -f "$SCRIPT_DIR/templates/omni-dex.xml" ]]; then
  SETUP_SCRIPT="$SCRIPT_DIR/setup.sh"
  OMNI_TEMPLATE="$SCRIPT_DIR/templates/omni.xml"
  DEX_TEMPLATE="$SCRIPT_DIR/templates/omni-dex.xml"
else
  TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/unraid-omni-install.XXXXXX")
  SETUP_SCRIPT="$TEMP_DIR/setup.sh"
  OMNI_TEMPLATE="$TEMP_DIR/omni.xml"
  DEX_TEMPLATE="$TEMP_DIR/omni-dex.xml"

  printf 'Downloading the latest Omni setup and Unraid templates...\n'
  download "$RAW_BASE/setup.sh" "$SETUP_SCRIPT"
  download "$RAW_BASE/templates/omni.xml" "$OMNI_TEMPLATE"
  download "$RAW_BASE/templates/omni-dex.xml" "$DEX_TEMPLATE"
fi

chmod +x "$SETUP_SCRIPT"

printf 'Configuring Omni...\n'
if [[ "${OMNI_SETUP_TEST_MODE:-0}" != 1 && -r /dev/tty && -w /dev/tty ]]; then
  "$SETUP_SCRIPT" "$@" </dev/tty
else
  "$SETUP_SCRIPT" "$@"
fi

mkdir -p "$TEMPLATE_DIR"
cp "$OMNI_TEMPLATE" "$TEMPLATE_DIR/my-omni.xml"
cp "$DEX_TEMPLATE" "$TEMPLATE_DIR/my-omni-dex.xml"
chmod 0644 "$TEMPLATE_DIR/my-omni.xml" "$TEMPLATE_DIR/my-omni-dex.xml"

cat <<EOF

Unraid templates installed or refreshed:
  $TEMPLATE_DIR/my-omni.xml
  $TEMPLATE_DIR/my-omni-dex.xml

Next steps in the Unraid WebUI:
  1. Open Docker -> Add Container.
  2. For Dex authentication, select Omni-Dex, apply it, and start it first.
  3. Select Omni, verify /mnt/user/appdata/omni (or your custom appdata path),
     then apply it.
  4. Open the Omni WebUI at the URL printed above.

Refresh the Docker page if the templates do not immediately appear.
EOF
