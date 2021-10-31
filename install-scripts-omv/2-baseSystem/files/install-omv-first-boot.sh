#!/bin/bash

if [[ $(id -u) -ne 0 ]]; then
  echo "This script must be executed as root or using sudo."
  exit 99
fi

declare -i cfg=0
declare -i rpi=1
declare -i skipFlash=0
declare -i skipNet=0
declare -i skipReboot=0
declare -i version

declare -l codename
declare -l omvCodename
declare -l omvInstall=""
declare -l omvextrasInstall=""

confCmd="omv-salt deploy run"
cpuFreqDef="/etc/default/cpufrequtils"
crda="/etc/default/crda"
defaultGovSearch="^CONFIG_CPU_FREQ_DEFAULT_GOV_"
forceIpv4="/etc/apt/apt.conf.d/99force-ipv4"
ioniceCron="/etc/cron.d/make_nas_processes_faster"
ioniceScript="/usr/sbin/omv-ionice"
rfkill="/usr/sbin/rfkill"
smbOptions="min receivefile size = 16384\ngetwd cache = yes"
wpaConf="/etc/wpa_supplicant/wpa_supplicant.conf"

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export LANG="en_US.UTF-8"
export LANGUAGE=en_US:en
export LC_NUMERIC="C"
export LC_CTYPE="C"
export LC_MESSAGES="C"
export LC_ALL="C"

while getopts "fhnr" opt; do
  echo "option ${opt}"
  case "${opt}" in
    f)
      skipFlash=1
      ;;
    h)
      echo "Use the following flags:"
      echo "  -f"
      echo "    to skip the installation of the flashmemory plugin"
      echo "  -n"
      echo "    to skip the network setup"
      echo "  -r"
      echo "    to skip reboot"
      echo ""
      echo "Examples:"
      echo "  install"
      echo "  install -f"
      echo "  install -n"
      exit 100
      ;;
    n)
      skipNet=1
      ;;
    r)
      skipReboot=1
      ;;
    \?)
      echo "Invalid option: -${OPTARG}"
      ;;
  esac
done

arch="$(dpkg --print-architecture)"

# exit if not supported architecture
case ${arch} in
  arm64|armhf|amd64|i386)
    echo "Supported architecture"
    ;;
  *)
    echo "Unsupported architecture :: ${arch}"
    exit 5
    ;;
esac

codename="$(lsb_release --codename --short)"

case ${codename} in
  buster)
    omvCodename="usul"
    version=5
    smbOptions="${smbOptions}\nwrite cache size = 524288"
    ;;
  bullseye)
    omvCodename="shaitan"
    version=6
    ;;
  *)
    echo "Unsupported version. Only Debian 10 (Buster) and 11 (Bullseye) are supported.  Exiting..."
    exit 1
  ;;
esac
echo "${omvCodename} :: ${version}"

hostname="raspberrypi"
domainname="local"
tz="$(timedatectl show --property=Timezone --value)"

regex='[a-zA-Z]([-a-zA-Z0-9]{0,61}[a-zA-Z0-9])'
if [[ ! ${hostname} =~ ${regex} ]]; then
    echo "Invalid hostname.  Exiting..."
    exit 6
fi

# install openmediavault if not installed already
omvInstall=$(dpkg -l | awk '$2 == "openmediavault" { print $1 }')
if [[ ! "${omvInstall}" == "ii" ]]; then
  echo "Installing openmediavault..."
  aptFlags="--yes --auto-remove --show-upgraded --allow-downgrades --allow-change-held-packages --no-install-recommends"
  cmd="apt-get ${aptFlags} install openmediavault"
  if ! ${cmd}; then
    echo "failed to install openmediavault package."
    exit 2
  fi

  omv-confdbadm populate
fi

# check if openmediavault is install properly
omvInstall=$(dpkg -l | awk '$2 == "openmediavault" { print $1 }')
if [[ ! "${omvInstall}" == "ii" ]]; then
  echo "openmediavault package failed to install or is in a bad state."
  exit 3
fi

. /etc/default/openmediavault
. /usr/share/openmediavault/scripts/helper-functions

# remove backports from sources.list to avoid duplicate sources warning
sed -i "/\(stretch\|buster\)-backports/d" /etc/apt/sources.list

if [ "${codename}" = "eoan" ]; then
  omv_set_default "OMV_APT_USE_KERNEL_BACKPORTS" false true
fi

if [ ${rpi} -eq 1 ]; then
  omv_set_default "OMV_APT_USE_OS_SECURITY" false true
fi

# install omv-extras
echo "Downloading omv-extras.org plugin for openmediavault ${version}.x ..."
file="openmediavault-omvextrasorg_latest_all${version}.deb"

if [ -f "/${file}" ]; then
  if ! dpkg --install /${file}; then
    echo "Installing other dependencies ..."
    apt-get --yes --fix-broken install
    omvextrasInstall=$(dpkg -l | awk '$2 == "openmediavault-omvextrasorg" { print $1 }')
    if [[ ! "${omvextrasInstall}" == "ii" ]]; then
      echo "omv-extras failed to install correctly.  Trying to fix with ${confCmd} ..."
      if ${confCmd} omvextras; then
        echo "Trying to fix apt ..."
        apt-get --yes --fix-broken install
      else
        echo "${confCmd} failed and openmediavault-omvextrasorg is in a bad state."
        exit 3
      fi
    fi
    omvextrasInstall=$(dpkg -l | awk '$2 == "openmediavault-omvextrasorg" { print $1 }')
    if [[ ! "${omvextrasInstall}" == "ii" ]]; then
      echo "openmediavault-omvextrasorg package failed to install or is in a bad state."
      exit 3
    fi
  fi
else
  echo "There was a problem downloading the package."
fi

# disable armbian log services if found
for service in log2ram armbian-ramlog armbian-zram-config; do
  if systemctl list-units --full -all | grep ${service}; then
    systemctl stop ${service}
    systemctl disable ${service}
  fi
done
rm -f /etc/cron.daily/armbian-ram-logging
if [ -f "/etc/default/armbian-ramlog" ]; then
  sed -i "s/ENABLED=.*/ENABLED=false/g" /etc/default/armbian-ramlog
fi
if [ -f "/etc/default/armbian-zram-config" ]; then
  sed -i "s/ENABLED=.*/ENABLED=false/g" /etc/default/armbian-zram-config
fi
if [ -f "/etc/systemd/system/logrotate.service" ]; then
  rm -f /etc/systemd/system/logrotate.service
  systemctl daemon-reload
fi

# install flashmemory plugin unless disabled
if [ ${skipFlash} -eq 1 ]; then
  echo "Skipping installation of the flashmemory plugin."
else
  echo "Install folder2ram..."
  if apt-get --yes --fix-missing --no-install-recommends install folder2ram; then
    echo "Installed folder2ram."
  else
    echo "Failed to install folder2ram."
  fi
  echo "Install flashmemory plugin..."
  if apt-get --yes install openmediavault-flashmemory; then
    echo "Installed flashmemory plugin."
  else
    echo "Failed to install flashmemory plugin."
    ${confCmd} flashmemory
    apt-get --yes --fix-broken install
  fi
fi

# change default OMV settings
omv_config_update "/config/services/smb/extraoptions" "$(echo -e "${smbOptions}")"
omv_config_update "/config/services/ssh/enable" "1"
omv_config_update "/config/services/ssh/permitrootlogin" "1"
omv_config_update "/config/system/time/ntp/enable" "1"
omv_config_update "/config/system/time/timezone" "${tz}"
omv_config_update "/config/system/network/dns/hostname" "${hostname}"
if [ -n "${domainname}" ]; then
  omv_config_update "/config/system/network/dns/domainname" "${domainname}"
fi

# disable monitoring and apply changes
echo "Disabling data collection ..."
/usr/sbin/omv-rpc -u admin "perfstats" "set" '{"enable":false}'
/usr/sbin/omv-rpc -u admin "config" "applyChanges" '{ "modules": ["monit","rrdcached","collectd"],"force": true }'

# set min/max frequency and watchdog for RPi boards
rpi_model="/proc/device-tree/model"
if [ -f "${rpi_model}" ] && [[ $(awk '{ print $1 }' ${rpi_model}) = "Raspberry" ]]; then
  omv_set_default "OMV_WATCHDOG_DEFAULT_MODULE" "bcm2835_wdt"
  omv_set_default "OMV_WATCHDOG_CONF_WATCHDOG_TIMEOUT" "14"

  MIN_SPEED="$(</sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq)"
  MAX_SPEED="$(</sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq)"
  # Determine if RPi4 (for future use)
  if [[ $(awk '$1 == "Revision" { print $3 }' /proc/cpuinfo) =~ [a-c]03111 ]]; then
    BOARD="rpi4"
  fi
  cat << EOF > ${cpuFreqDef}
GOVERNOR="ondemand"
MIN_SPEED="${MIN_SPEED}"
MAX_SPEED="${MAX_SPEED}"
EOF
fi

if [ -f "${cpuFreqDef}" ]; then
  . ${cpuFreqDef}
else
  # set cpufreq settings if no defaults
  if [ -f "/proc/config.gz" ]; then
    defaultGov="$(zgrep "${defaultGovSearch}" /proc/config.gz | sed -e "s/${defaultGovSearch}\(.*\)=y/\1/")"
  elif [ -f "/boot/config-$(uname -r)" ]; then
    defaultGov="$(grep "${defaultGovSearch}" /boot/config-"$(uname -r)" | sed -e "s/${defaultGovSearch}\(.*\)=y/\1/")"
  fi
  if [ -z "${DEFAULT_GOV}" ]; then
    defaultGov="ondemand"
  fi
  GOVERNOR=${defaultGov,,}
  MIN_SPEED="0"
  MAX_SPEED="0"
fi

# set defaults in /etc/default/openmediavault
omv_set_default "OMV_CPUFREQUTILS_GOVERNOR" "${GOVERNOR}"
omv_set_default "OMV_CPUFREQUTILS_MINSPEED" "${MIN_SPEED}"
omv_set_default "OMV_CPUFREQUTILS_MAXSPEED" "${MAX_SPEED}"

# update pillar default list - /srv/pillar/omv/default.sls
omv-salt stage run prepare

# update config files
${confCmd} nginx phpfpm samba flashmemory ssh chrony timezone monit rrdcached collectd cpufrequtils apt watchdog

# create php directories if they don't exist
modDir="/var/lib/php/modules"
if [ ! -d "${modDir}" ]; then
  mkdir --parents --mode=0755 ${modDir}
fi
sessDir="/var/lib/php/sessions"
if [ ! -d "${sessDir}" ]; then
  mkdir --parents --mode=1733 ${sessDir}
fi

if [ -f "${forceIpv4}" ]; then
  rm ${forceIpv4}
fi

if [ -f "/etc/init.d/proftpd" ]; then
  systemctl disable proftpd.service
  systemctl stop proftpd.service
fi

if [[ "${arch}" == "amd64" ]] || [[ "${arch}" == "i386" ]]; then
  # skip ionice on x86 boards
  echo "Done."
  exit 0
fi

# Add a cron job to make NAS processes more snappy and silence rsyslog
cat << EOF > /etc/rsyslog.d/omv-armbian.conf
:msg, contains, "omv-ionice" ~
:msg, contains, "action " ~
:msg, contains, "netsnmp_assert" ~
:msg, contains, "Failed to initiate sched scan" ~
EOF
systemctl restart rsyslog

# add taskset to ionice cronjob for biglittle boards
case ${BOARD} in
  odroidxu4|bananapim3|nanopifire3|nanopct3plus|nanopim3)
    taskset='; taskset -c -p 4-7 ${srv}'
    ;;
  *rk3399*|*edge*|nanopct4|nanopim4|nanopineo4|renegade-elite|rockpi-4*|rockpro64|helios64)
    taskset='; taskset -c -p 4-5 ${srv}'
    ;;
  odroidn2)
    taskset='; taskset -c -p 2-5 ${srv}'
    ;;
esac

# create ionice script
cat << EOF > ${ioniceScript}
#!/bin/sh

for srv in \$(pgrep "ftpd|nfsiod|smbd"); do
  ionice -c1 -p \${srv} ${taskset};
done
EOF
chmod 755 ${ioniceScript}

# create ionice cronjob
cat << EOF > ${ioniceCron}
* * * * * root ${ioniceScript} >/dev/null 2>&1
EOF
chmod 600 ${ioniceCron}

# add pi user to ssh group if it exists
if getent passwd pi > /dev/null; then
  echo "Adding pi user to ssh group ..."
  usermod -a -G ssh pi
fi

# add user running the script to ssh group if not pi or root
if [ -n "${USER}" ] && [ ! "${USER}" = "root" ] && [ ! "${USER}" = "pi" ]; then
  if getent passwd ${USER} > /dev/null; then
    echo "Adding ${USER} to the ssh group ..."
    usermod -a -G ssh ${USER}
  fi
fi

# remove networkmanager and dhcpcd5 then configure networkd
if [ ${skipNet} -ne 1 ]; then

  if [ "${BOARD}" = "helios64" ]; then
    echo -e '#!/bin/sh\n/usr/sbin/ethtool --offload eth1 rx off tx off' > /usr/lib/networkd-dispatcher/routable.d/10-disable-offloading
  fi

  defLink="/etc/systemd/network/99-default.link"
  if [ -e "${defLink}" ]; then
    rm -fv "${defLink}"
  fi

  echo "Removing network-manager and dhcpcd5 ..."
  apt-get -y --autoremove purge network-manager dhcpcd5

  echo "Enable and start systemd-resolved ..."
  systemctl enable systemd-resolved
  systemctl start systemd-resolved
  rm /etc/resolv.conf
  ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf

  if [ -f "${rfkill}" ]; then
    echo "Unblocking wifi with rfkill ..."
    ${rfkill} unblock all
  fi

  for nic in $(ls /sys/class/net | grep -vE "br-|docker|dummy|lo|tun|virbr|wg"); do
    if grep -q "<devicename>${nic}</devicename>" ${OMV_CONFIG_FILE}; then
      echo "${nic} already found in database.  Skipping..."
      continue
    fi
    if udevadm info /sys/class/net/${nic} | grep -q wlan; then
      if [ -f "${wpaConf}" ]; then
        country=$(awk -F'=' '/country=/{gsub(/["\r]/,""); print $NF}' ${wpaConf})
        wifiName=$(awk -F'=' '/ssid="/{st=index($0,"="); ssid=substr($0,st+1); gsub(/["\r]/,"",ssid); print ssid; exit}' ${wpaConf})
        wifiPass=$(awk -F'=' '/psk="/{st=index($0,"="); pass=substr($0,st+1); gsub(/["\r]/,"",pass); print pass; exit}' ${wpaConf})

        if [ -n "${country}" ] && [ -n "${wifiName}" ] && [ -n "${wifiPass}" ]; then
          if [ -f "${crda}" ]; then
            awk -i inplace -F'=' -v country="$country" '/REGDOMAIN=/{$0=$1"="country} {print $0}' ${crda}
          fi
          echo "Adding ${nic} to openmedivault database ..."
          jq --null-input --compact-output \
            "{uuid: \"${OMV_CONFIGOBJECT_NEW_UUID}\", devicename: \"${nic}\", type: \"wifi\", method: \"dhcp\", method6: \"dhcp\", wpassid: \"${wifiName}\", wpapsk: \"${wifiPass}\"}" | \
            omv-confdbadm update "conf.system.network.interface" -
          if grep -q "<devicename>${nic}</devicename>" ${OMV_CONFIG_FILE}; then
            cfg=1
          fi
        fi
      fi
    else
      echo "Adding ${nic} to openmedivault database ..."
      if [ -n "$(ip -j -o -4 addr show ${nic} | jq --raw-output  '.[] | select(.addr_info[0].dev) | .addr_info[0].local')" ] && \
      [ "$(ip -j -o -4 addr show ${nic} | jq --raw-output '.[] | select(.addr_info[0].dev) | .addr_info[0].dynamic')" == "null" ]; then
        ipv4Addr=$(ip -j -o -4 addr show ${nic} | jq --raw-output '.[] | select(.addr_info[0].dev) | .addr_info[0].local')
        ipv4CIDR=$(ip -j -o -4 addr show ${nic} | jq --raw-output '.[] | select(.addr_info[0].dev) | .addr_info[0].prefixlen')
        bitmaskValue=$(( 0xffffffff ^ ((1 << (32 - ipv4CIDR)) - 1) ))
        ipv4Netmask=$(( (bitmaskValue >> 24) & 0xff )).$(( (bitmaskValue >> 16) & 0xff )).$(( (bitmaskValue >> 8) & 0xff )).$(( bitmaskValue & 0xff ))
        ipv4GW=$(ip -j -o -4 route show | jq --raw-output '.[] | select(.dst=="default") | .gateway')
        jq --null-input --compact-output \
        "{uuid: \"${OMV_CONFIGOBJECT_NEW_UUID}\", devicename: \"${nic}\", method: \"static\", address: \"${ipv4Addr}\", netmask: \"${ipv4Netmask}\", gateway: \"${ipv4GW}\", dnsnameservers: \"8.8.8.8 ${ipv4GW}\"}" | \
        omv-confdbadm update "conf.system.network.interface" -
      else
        jq --null-input --compact-output \
        "{uuid: \"${OMV_CONFIGOBJECT_NEW_UUID}\", devicename: \"${nic}\", method: \"dhcp\", method6: \"dhcp\"}" | \
        omv-confdbadm update "conf.system.network.interface" -
      fi

      if grep -q "<devicename>${nic}</devicename>" ${OMV_CONFIG_FILE}; then
        cfg=1
      fi
    fi
  done

  if [ ${cfg} -eq 1 ]; then
    echo "IP address may change and you could lose connection if running this script via ssh."

    # create config files
    if ! ${confCmd} systemd-networkd; then
      echo "Error applying network changes.  Skipping reboot!"
      skipReboot=1
    fi

    if [ ${skipReboot} -ne 1 ]; then
      echo "Network setup.  Rebooting..."
      reboot
    fi
  else
    echo "It is recommended to reboot and then setup the network adapter in the openmediavault web interface."
  fi

fi

exit 0
