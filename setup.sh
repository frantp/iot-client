#!/bin/sh -e

die() { [ "$#" -eq 0 ] || echo "$*" >&2; exit 1; }

usage() {
    echo ""
    echo "Usage: $0 [options] [cfg_url]"
    echo ""
    echo "Arguments:"
    echo "  cfg_url  URL to search for configuration files (defaults to SREADER_CFG_URL)"
    echo ""
    echo "Options:"
    echo "  -h  Show this help message"
    echo "  -s  Omit installation of system requirements"
    echo "  -p  Omit installation of Python requirements"
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
while getopts "hsp" arg; do
    case "${arg}" in
        h) usage; exit 0 ;;
        s) omit_system_reqs=true ;;
        p) omit_python_reqs=true ;;
    esac
done
shift $(( OPTIND - 1 ))

SRC_DIR="/opt/iot-client"
LIB_DIR="/var/lib/sreader"
LOG_DIR="/var/log/sreader"
SERVICES_DIR="/etc/systemd/system"
TMP_DIR="/run/sreader"
MAIN_EXE="/usr/local/bin/sreader"
UPDATER_EXE="/usr/local/bin/sreader-update"
LOGROTATE_CFG="/etc/logrotate.d/sreader"

cfg_url="${1:-${SREADER_CFG_URL}}"

cd "${SRC_DIR}"

mkdir -p "${LIB_DIR}" "${LOG_DIR}" "${TMP_DIR}"

# System requirements
if [ -z "${omit_system_reqs}" ]; then
    echo "Installing system requirements"
    until [ -n "${installed}" ]; do
        . "/etc/os-release"
        curl -sL "https://repos.influxdata.com/influxdb.key" | sudo apt-key add - && \
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

# Configuration
echo "Configuring"
raspi-config nonint do_i2c 0
raspi-config nonint do_serial 2

# Python requirements
if [ -z "${omit_python_reqs}" ]; then
    echo "- Installing Python requirements"
    python3 -m venv "${LIB_DIR}/env"
    . "${LIB_DIR}/env/bin/activate"
    pip3 install --no-cache-dir -r "sreader/requirements.txt"
    deactivate
fi

# Files
echo "Installing files"
# - Exe
if ! diff -q "${SRC_DIR}/sreader.sh" "${MAIN_EXE}" > /dev/null; then
    cp "${SRC_DIR}/sreader.sh" "${MAIN_EXE}"
    sreader_changed=true
fi
chmod +x "${MAIN_EXE}"
# - Services
unit="sreader.service"
if ! diff -q "${SRC_DIR}/systemd/${unit}" "${SERVICES_DIR}/${unit}" > /dev/null; then
    cp "${SRC_DIR}/systemd/${unit}" "${SERVICES_DIR}/${unit}"
    reload_services=true
    sreader_changed=true
fi
unit="sreader-update.service"
if ! diff -q "${SRC_DIR}/systemd/${unit}" "${SERVICES_DIR}/${unit}" > /dev/null; then
    cp "${SRC_DIR}/systemd/${unit}" "${SERVICES_DIR}/${unit}"
    reload_services=true
fi
unit="sreader-update.timer"
if ! diff -q "${SRC_DIR}/systemd/${unit}" "${SERVICES_DIR}/${unit}" > /dev/null; then
    cp "${SRC_DIR}/systemd/${unit}" "${SERVICES_DIR}/${unit}"
    reload_services=true
    systemctl restart "${unit}"
fi
# - Logrotate
cp "logrotate.conf" "${LOGROTATE_CFG}"
# - Updater
cp "${SRC_DIR}/update.sh" "${UPDATER_EXE}"
chmod +x "${UPDATER_EXE}"

# Configuration files
echo "Updating configuration files"
download_github_file "${cfg_url}/mosquitto.conf" "${TMP_DIR}/mosquitto.conf"
if ! diff -q "${TMP_DIR}/mosquitto.conf" "/etc/mosquitto/conf.d/sreader.conf" > /dev/null; then
    echo "Restarting mosquitto"
    mv "${TMP_DIR}/mosquitto.conf" "/etc/mosquitto/conf.d/sreader.conf"
    systemctl restart mosquitto
fi
download_github_file "${cfg_url}/telegraf.conf" "${TMP_DIR}/telegraf.conf"
if ! diff -q "${TMP_DIR}/telegraf.conf" "/etc/telegraf/telegraf.conf" > /dev/null; then
    echo "Restarting telegraf"
    mv "${TMP_DIR}/telegraf.conf" "/etc/telegraf/telegraf.conf"
    systemctl restart telegraf
fi
download_github_file "${cfg_url}/sreader.conf" "${TMP_DIR}/sreader.conf"
if ! diff -q "${TMP_DIR}/sreader.conf" "/etc/sreader.conf" > /dev/null; then
    mv "${TMP_DIR}/sreader.conf" "/etc/sreader.conf"
    sreader_changed=true
fi

# Services
echo "Setting up services"
if [ -n "${reload_services}" ]; then
    echo "Reloading services"
    systemctl daemon-reload
fi
if [ -n "${sreader_changed}" ]; then
    echo "Restarting sreader"
    systemctl restart sreader
fi
systemctl is-enabled mosquitto            > /dev/null || systemctl enable mosquitto
systemctl is-enabled telegraf             > /dev/null || systemctl enable telegraf
systemctl is-enabled sreader              > /dev/null || systemctl enable sreader
systemctl is-enabled sreader-update.timer > /dev/null || systemctl enable sreader-update.timer
systemctl is-active  mosquitto            > /dev/null || systemctl restart mosquitto
systemctl is-active  telegraf             > /dev/null || systemctl restart telegraf
systemctl is-active  sreader              > /dev/null || systemctl restart sreader
systemctl is-active  sreader-update.timer > /dev/null || systemctl restart sreader-update.timer

echo "Finished"
