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

# Configuration
echo "Configuring"
raspi-config nonint do_i2c 0
raspi-config nonint do_serial 0

# Dependencies
echo "Installing dependencies"
until [ -n "${installed}" ]; do
    apt-get -qq update && \
    apt-get -qq install curl git jq python3 python3-venv mosquitto && \
    installed=true || true
    if [ -z "${installed}" ]; then
        echo "Retrying installation"
        sleep 1
    fi
done
systemctl enable mosquitto

# IOT Client
echo "Installing IOT client"
rm -rf "${SRC_DIR}"
git clone --recurse-submodules "https://github.com/frantp/iot-client.git" "${SRC_DIR}"
"${SRC_DIR}/update.sh" -f "${cfg_url}"
