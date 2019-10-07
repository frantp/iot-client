#!/bin/sh -e

usage() {
    echo ""
    echo "Usage: $0 [cfg_url]"
    echo ""
    echo "Arguments:"
    echo "  cfg_url  URL to search for configuration files (defaults to PIOT_CFG_URL)"
}

SRC_DIR="/opt/piot-client"

cfg_url="${1:-${PIOT_CFG_URL}}"

echo "[$(date -Ins)] Installing Piot client"
apt-get -qq update
apt-get -qq install git curl
rm -rf "${SRC_DIR}"
git clone --recurse-submodules "https://github.com/frantp/piot-client.git" "${SRC_DIR}"
"${SRC_DIR}/install.sh" "${cfg_url}"
