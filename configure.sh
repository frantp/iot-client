#!/bin/bash

die() { [ "$#" -eq 0 ] || echo "$*" >&2; exit 1; }

usage() {
    echo ""
    echo "Usage:"
    echo "  $0 [options] <root_dir> [<boot_dir>]"
    echo "  $0 [options] <img_file> [<mount_dir>]"
    echo ""
    echo "Arguments:"
    echo "  root_dir:      Directory of the root partition to edit, when already mounted"
    echo "  boot_dir:      Directory of the boot partition to edit, when already mounted"
    echo "                 [default: <root_dir>/boot]"
    echo "  img_file:      Image file to mount and edit"
    echo "  mount_dir:     Directory to create the mount points for the partitions inside"
    echo "                 the image file [default: /mnt]"
    echo ""
    echo "Options:"
    echo "  -h             Show this help message"
    echo "  -m             Wait after mounting image to allow for manual modifications"
    echo "                 (valid only when an image file is specified)"
    echo "  -p <user>      Change password for user"
    echo "  -n <hostname>  Change hostname"
    echo "  -s             Enable SSH server"
    echo "  -r             Set WiFi auto-reconnect"
    echo "  -w <ssid>      Add WiFi SSID and password (can be defined multiple times)"
    echo "  -c <code>      Set WiFi country code"
    echo "  -i <ip>        Set static IP"
    echo "  -e <env_str>   Set environment variable, with the form VAR=VAL (can be"
    echo "                 defined multiple times)"
    echo "  -x             Install Piot client; PIOT_CFG_URL should be set"
}

release_image() {
    if [ -n "${boot_dir}" ] && [ -n "${root_dir}" ]; then
        echo "Unmounting image partitions"
        umount "${boot_dir}" "${root_dir}" && \
        rmdir "${boot_dir}" "${root_dir}"
    fi
    echo "Deleting partition mappings"
    kpartx -d "${init_path}" > /dev/null
}

clean_previous_cfg() {
    sed -i "/^${MARKER_STR}/,/^${MARKER_END}/d" "$1"
}

MARKER_STR="### INSTALLER ###"
MARKER_END="### --------- ###"

# Parse arguments
wifi_ssids=()
env_strs=()
while getopts "hmp:n:srw:c:i:e:x" arg; do
    case "${arg}" in
        h) usage; exit 0 ;;
        m) wait_manual=true ;;
        p) passwd_user="${OPTARG}" ;;
        n) host_name="${OPTARG}" ;;
        s) enable_ssh=true ;;
        r) set_autoreconnect=true ;;
        w) wifi_ssids+=("${OPTARG}") ;;
        c) wifi_country="${OPTARG}" ;;
        i) static_ip="${OPTARG}" ;;
        e) env_strs+=("${OPTARG}") ;;
        x) install_piot_client=true; ;;
    esac
done
shift $(( OPTIND - 1 ))

init_path="${1?"$(usage)"}"

# Download image if necessary
if [ ! -e "${init_path}" ]; then
    if [ ! -e "${init_path}.zip" ]; then
        echo "Downloading image"
        wget "https://downloads.raspberrypi.org/raspbian_lite_latest" -O "${init_path}.zip" || \
            die "Failed"
        downloaded=true
    fi

    echo "Extracting image"
    apt-get -qq install unzip && \
    unzip -p "${init_path}.zip" > "${init_path}" || \
        die "Failed"

    if [ -n "${downloaded}" ]; then
        rm "${init_path}.zip"
    fi
fi

# Mount if necessary
if [ -f "${init_path}" ]; then
    mount_dir="${2:-/mnt}"
    echo "Creating partition mappings"
    apt-get -qq install kpartx && \
    trap release_image 0 && \
    res="$(kpartx -asv "${init_path}")" || \
        die "Failed"
    read -d '' boot_map root_map <<< $(echo "$res" | head -n 2 | grep -o 'loop[^ ]*')

    echo "Mounting image partitions"
    bd="${mount_dir}/boot"
    rd="${mount_dir}/rootfs"
    n=0
    while [ -e "${bd}" ] || [ -e "${rd}" ]; do
        ((n++))
        bd="${mount_dir}/boot${n}"
        rd="${mount_dir}/rootfs${n}"
    done
    boot_dir="${bd}"
    root_dir="${rd}"
    mkdir -p "${boot_dir}" "${root_dir}" && \
    mount "/dev/mapper/${boot_map}" "${boot_dir}" && \
    mount "/dev/mapper/${root_map}" "${root_dir}" || \
        die "Failed"

    # Wait for manual configuration
    if [ -n "${wait_manual}" ]; then
        read -p "Waiting, press ENTER to continue"
    fi
else
    root_dir="${init_path}"
    boot_dir="${2:-${root_dir}/boot}"
fi

# Change password
if [ -n "${passwd_user}" ]; then
    echo "Changing password for user '${passwd_user}'"
    passwd="$(openssl passwd -1)" && \
    sed -i "s|${passwd_user}:[^:]*|${passwd_user}:${passwd}|" "${root_dir}/etc/shadow" || \
        echo "Failed"
fi

# Change hostname
if [ -n "${host_name}" ]; then
    echo "Changing hostname to '${host_name}'"
    old_host_name="$(cat "${root_dir}/etc/hostname")" && \
    sed -i "s/${old_host_name}/${host_name}/g" "${root_dir}/etc/hostname" && \
    sed -i "s/${old_host_name}/${host_name}/g" "${root_dir}/etc/hosts" || \
        echo "Failed"
fi

# Enable SSH
if [ -n "${enable_ssh}" ]; then
    echo "Enabling SSH"
    touch "${boot_dir}/ssh"
fi

# Autoreconnect
if [ -n "${set_autoreconnect}" ]; then
    echo "Setting network auto-reconnect"
    ouf_file="${root_dir}/etc/network/interfaces"
cfg="${MARKER_STR}
auto wlan0
allow-hotplug wlan0
iface wlan0 inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
iface default inet dhcp
${MARKER_END}" && \
    clean_previous_cfg "${ouf_file}" && \
    echo "${cfg}" >> "${ouf_file}" || \
        echo "Failed"
fi

# Configure WiFi SSID/password
for wifi_ssid in "${wifi_ssids[@]}"; do
    echo "Configuring WiFi '${wifi_ssid}'"
    read -sp "Password: " wifi_passwd && \
    ouf_file="${root_dir}/etc/wpa_supplicant/wpa_supplicant.conf"
cfg="
network={
    ssid=\"${wifi_ssid}\"
    psk=\"${wifi_passwd}\"
    key_mgmt=WPA-PSK
    scan_ssid=1
}"
    clean_previous_cfg "${ouf_file}" && \
    echo "${cfg}" >> "${ouf_file}" || \
        echo "Failed"
done

# Set WiFi country
if [ -n "${wifi_country}" ]; then
    echo "Setting WiFi country to '${wifi_country}'"
    ouf_file="${root_dir}/etc/wpa_supplicant/wpa_supplicant.conf"
    sed -i "s/country=.*/country=${wifi_country}/" "${ouf_file}" || \
        echo "Failed"
fi

# Set static IP address
if [ -n "${static_ip}" ]; then
    echo "Setting static IP address '${static_ip}'"
    ouf_file="${root_dir}/etc/dhcpcd.conf"
cfg="${MARKER_STR}
interface wlan0
static ip_address=${static_ip}/24
static routers=${static_ip%.*}.1
static domain_name_servers=${static_ip%.*}.1 8.8.8.8
${MARKER_END}"
    clean_previous_cfg "${ouf_file}" && \
    echo "${cfg}" >> "${ouf_file}" || \
        echo "Failed"
fi

# Set environment variable
for env_str in "${env_strs[@]}"; do
    echo "Setting environment variable '${env_str}'"
    out_file="${root_dir}/etc/environment"
    env_var="${env_str%%=*}"
    sed -i "/^${env_var}=/d" "${out_file}" && echo "${env_str}" >> "${out_file}"
done

# Install Piot client
if [ -n "${install_piot_client}" ]; then
    echo "Installing Piot client"
    INSTALLER_BIN="/usr/local/bin/piot-install"
    INSTALLER_LOG="/var/log/piot/installer.log"
    ouf_file="${root_dir}/etc/rc.local"
    clean_previous_cfg "${ouf_file}" && \
    wget "https://raw.githubusercontent.com/frantp/piot-client/master/install.sh" -qO "${root_dir}/${INSTALLER_BIN}" && \
    chmod +x "${root_dir}/${INSTALLER_BIN}" && \
    end="$(tail -n 1 "${ouf_file}")" && sed -i '$d' "${ouf_file}" && \
cfg="${MARKER_STR}
set -a; . \"/etc/environment\"; set +a
mkdir -p \"$(dirname "${INSTALLER_LOG}")\"
\"${INSTALLER_BIN}\" >> \"${INSTALLER_LOG}\" 2>&1 && \\
rm \"${INSTALLER_BIN}\" && \\
sed -i \"/^${MARKER_STR}/,/^${MARKER_END}/d\" \"/etc/rc.local\"
${MARKER_END}
${end}" && \
    echo "${cfg}" >> "${ouf_file}" || \
        echo "Failed"
fi

echo "Finished"
