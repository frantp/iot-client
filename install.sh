#!/bin/sh

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
LIB_DIR="/var/lib/piot"
LOG_DIR="/var/log/piot"
TMP_DIR="/run/piot"
MAIN_EXE="/usr/local/bin/piot"
LOGROTATE_CFG="/etc/logrotate.d/piot"

mkdir -p "${LIB_DIR}" "${LOG_DIR}" "${TMP_DIR}"

cd "${SRC_DIR}"

# System dependencies
. "/etc/os-release"
curl -sL "https://repos.influxdata.com/influxdb.key" | \
	APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=1 apt-key add - > /dev/null
echo "deb https://repos.influxdata.com/debian ${VERSION_CODENAME} stable" \
	> "/etc/apt/sources.list.d/influxdb.list"
if [ -z "${omit_system_reqs}" ]; then
	echo "Installing system dependencies..."
    apt-get -qq update
    DEBIAN_FRONTEND=noninteractive \
        apt-get -qq install $(cat dependencies.txt | tr '\n' ' ')
fi
echo "[rabbitmq_management, rabbitmq_shovel, rabbitmq_shovel_managememt]." \
	> "/etc/rabbitmq/enabled_plugins"

# Python requirements
if [ -z "${omit_python_reqs}" ]; then
	echo "Installing Python requirements..."
	python3 -m venv "${LIB_DIR}/env"
	. "${LIB_DIR}/env/bin/activate"
	python3 -m pip3 install --no-cache-dir -r "piot/requirements.txt"
	deactivate
fi

# Piot
echo "Installing Piot..."
ln -sf "${SRC_DIR}/piot.sh" "${MAIN_EXE}"  # Main exe
find "systemd" -type f \
	-exec sh -c 'mkdir -p "$(dirname "/etc/$0")"' "{}" \; \
	-exec ln -sf "${SRC_DIR}/{}" "/etc/{}" \; # Services
ln -sf "${SRC_DIR}/logrotate.conf" "${LOGROTATE_CFG}"  # Logrotate

echo "Finished"
