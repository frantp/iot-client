#!/bin/sh -e

die() { [ "$#" -eq 0 ] || echo "$*" >&2; exit 1; }

usage() {
	cat <<- EOM
		Usage: $0 [options]

		Options:
		  -h  Show this help message
		  -s  Omit installation of system dependencies
		  -p  Omit installation of Python requirements
	EOM
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

SRC_DIR="$(dirname "$(realpath "$0")")"
SRV_DIR="/etc/systemd/system"
LIB_DIR="/var/lib/piot"
LOG_DIR="/var/log/piot"
TMP_DIR="/run/piot"
MAIN_EXE="/usr/local/bin/piot"
UPDATER_EXE="/usr/local/bin/piot-update"
LOGROTATE_CFG="/etc/logrotate.d/piot"

mkdir -p "${LIB_DIR}" "${LOG_DIR}" "${TMP_DIR}"

cd "${SRC_DIR}"

# System dependencies
if [ -z "${omit_system_reqs}" ]; then
	echo "Installing system dependencies..."
    . "/etc/os-release"
    curl -sL "https://repos.influxdata.com/influxdb.key" | \
        APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=1 apt-key add - > /dev/null
    echo "deb https://repos.influxdata.com/debian ${VERSION_CODENAME} stable" \
        > "/etc/apt/sources.list.d/influxdb.list"
    apt-get -qq update
    DEBIAN_FRONTEND=noninteractive \
        apt-get -qq install $(cat dependencies.txt | tr '\n' ' ')
fi

# Python requirements
if [ -z "${omit_python_reqs}" ]; then
	echo "Installing Python requirements..."
	python3 -m venv "${LIB_DIR}/env"
	. "${LIB_DIR}/env/bin/activate"
	python3 -m pip install --no-cache-dir -r "piot/requirements.txt"
	deactivate
fi

# Piot
echo "Installing Piot..."
chmod +x *.sh
ln -sf "${SRC_DIR}/piot.sh" "${MAIN_EXE}"  # Main exe
for unit in piot.service piot-update.service piot-update.timer; do
	ln -sf "${SRC_DIR}/systemd/${unit}" "${SRV_DIR}/${unit}"  # Services
done
ln -sf "${SRC_DIR}/logrotate.conf" "${LOGROTATE_CFG}"  # Logrotate
ln -sf "${SRC_DIR}/update.sh" "${UPDATER_EXE}"  # Updater

echo "Finished"
