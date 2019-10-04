#!/bin/sh -e

die() { [ "$#" -eq 0 ] || echo "$*" >&2; exit 1; }

usage() {
    echo ""
    echo "Usage: $0 [options] [cfg_url]"
    echo ""
    echo "Arguments:"
    echo "  cfg_url  URL to search for configuration files (defaults to PIOT_CFG_URL)"
    echo ""
    echo "Options:"
    echo "  -h  Show this help message"
    echo "  -o  Omit installation of Piot"
    echo "  -p  Omit installation of Python requirements"
    echo "  -s  Omit installation of system requirements"
}

download_github_file() {
    url="${1?"URL not provided"}"
    path="${2?"Path not provided"}"
    res="$(wget "${url}" -qO-)" || \
        die "Configuration file not found at '${url}'"
    echo "${res}" | tr -d '\r\n' | jq -r '.content' | base64 -d > "${path}"
    echo "- Downloaded '${url}' to '${path}'"
}

# Parse arguments
while getopts "hosp" arg; do
    case "${arg}" in
        h) usage; exit 0 ;;
        o) omit_installation=true ;;
        s) omit_system_reqs=true ;;
        p) omit_python_reqs=true ;;
    esac
done
shift $(( OPTIND - 1 ))

SRC_DIR="/opt/piot-client"
LIB_DIR="/var/lib/piot"
LOG_DIR="/var/log/piot"
SERVICES_DIR="/etc/systemd/system"
TMP_DIR="/run/piot"
MAIN_EXE="/usr/local/bin/piot"
UPDATER_EXE="/usr/local/bin/piot-update"
LOGROTATE_CFG="/etc/logrotate.d/piot"

cfg_url="${1:-${PIOT_CFG_URL}}"

cd "${SRC_DIR}"

if [ -z "${omit_installation}" ]; then
    mkdir -p "${LIB_DIR}" "${LOG_DIR}" "${TMP_DIR}"

    # System requirements
    if [ -z "${omit_system_reqs}" ]; then
        echo "Installing system requirements"
        until [ -n "${installed}" ]; do
            . "/etc/os-release"
            curl -sL "https://repos.influxdata.com/influxdb.key" | sudo apt-key add - > /dev/null && \
            echo "deb https://repos.influxdata.com/debian ${VERSION_CODENAME} stable" > "/etc/apt/sources.list.d/influxdb.list" && \
            apt-get -qq update && \
            DEBIAN_FRONTEND=noninteractive \
            apt-get -qq install $(cat requirements.list | tr '\n' ' ') && \
            installed=true || true
            if [ -z "${installed}" ]; then
                echo "Retrying installation"
                sleep 1
            fi
        done
    fi

    # Python requirements
    if [ -z "${omit_python_reqs}" ]; then
        echo "- Installing Python requirements"
        python3 -m venv "${LIB_DIR}/env"
        . "${LIB_DIR}/env/bin/activate"
        pip3 install --no-cache-dir -r "piot/requirements.txt"
        deactivate
    fi

    # Configuration
    echo "Configuring"
    raspi-config nonint do_i2c 0
    raspi-config nonint do_serial 2

    # Piot
    echo "Installing Piot"
    chmod +x *.sh
    ln -sf "${SRC_DIR}/piot.sh" "${MAIN_EXE}"  # Main exe
    for unit in "piot.service" "piot-update.service" "piot-update.timer"; do
        ln -sf "${SRC_DIR}/systemd/${unit}" "${SERVICES_DIR}/${unit}"  # Services
    done
    systemctl daemon-reload
    ln -sf "${SRC_DIR}/logrotate.conf" "${LOGROTATE_CFG}"  # Logrotate
    ln -sf "${SRC_DIR}/update.sh" "${UPDATER_EXE}"  # Updater

    restart_piot=true
fi

# Configuration files
echo "Updating configuration files"
download_github_file "${cfg_url}/mosquitto.conf" "${TMP_DIR}/mosquitto.conf"
if ! diff -q "${TMP_DIR}/mosquitto.conf" "/etc/mosquitto/conf.d/piot.conf" > /dev/null; then
    mv "${TMP_DIR}/mosquitto.conf" "/etc/mosquitto/conf.d/piot.conf"
    restart_mosquitto=true
fi
download_github_file "${cfg_url}/telegraf.conf" "${TMP_DIR}/telegraf.conf"
if ! diff -q "${TMP_DIR}/telegraf.conf" "/etc/telegraf/telegraf.conf" > /dev/null; then
    mv "${TMP_DIR}/telegraf.conf" "/etc/telegraf/telegraf.conf"
    restart_telegraf=true
fi
download_github_file "${cfg_url}/piot.conf" "${TMP_DIR}/piot.conf"
if ! diff -q "${TMP_DIR}/piot.conf" "/etc/piot.conf" > /dev/null; then
    mv "${TMP_DIR}/piot.conf" "/etc/piot.conf"
    restart_piot=true
fi

# Services
echo "Setting up services"
if [ -n "${restart_mosquitto}" ]; then
    echo "- Restarting mosquitto"
    systemctl restart mosquitto
fi
if [ -n "${restart_telegraf}" ]; then
    echo "- Restarting telegraf"
    systemctl restart telegraf
fi
if [ -n "${restart_piot}" ]; then
    echo "- Restarting piot and piot-update.timer"
    systemctl restart piot
    systemctl restart piot-update.timer
fi
for unit in "mosquitto" "telegraf" "piot" "piot-update.timer"; do
    systemctl is-enabled "${unit}" > /dev/null || { echo "- Enabling ${unit}" && systemctl enable "${unit}"; }
    systemctl is-active  "${unit}" > /dev/null || { echo "- Starting ${unit}" && systemctl restart "${unit}"; }
done

echo "Finished"
