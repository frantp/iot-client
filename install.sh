#!/bin/sh -e

usage() {
    echo ""
    echo "Usage: $0 [cfg_url]"
    echo ""
    echo "Arguments:"
    echo "  cfg_url  URL to search for configuration files (defaults to SREADER_CFG_URL)"
}

SRC_DIR="/opt/iot-client"

cfg_url="${1:-${SREADER_CFG_URL}}"

echo "Installing IOT client"
rm -rf "${SRC_DIR}"
git clone --recurse-submodules "https://github.com/frantp/iot-client.git" "${SRC_DIR}"
"${SRC_DIR}/update.sh" -f "${cfg_url}"
