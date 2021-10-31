#!/bin/bash
#
# See original at: https://raw.githubusercontent.com/OpenMediaVault-Plugin-Developers/installScript/master/install
#
# shellcheck disable=SC1090,SC1091,SC1117,SC2010,SC2016,SC2046,SC2086,SC2174
#
# Copyright (c) 2015-2021 OpenMediaVault Plugin Developers
# Copyright (c) 2017-2020 Armbian Developers
#
# This file is licensed under the terms of the GNU General Public
# License version 2. This program is licensed "as is" without any
# warranty of any kind, whether express or implied.
#
# Ideas/code used from:
# https://github.com/armbian/config/blob/master/debian-software
# https://forum.openmediavault.org/index.php/Thread/25062-Install-OMV5-on-Debian-10-Buster/
#
# version: 1.5.2
#

if [[ $(id -u) -ne 0 ]]; then
  echo "This script must be executed as root or using sudo."
  exit 99
fi

declare -i ipv6=0
declare -i version
declare -i skipFlash=0
declare -l codename
declare -l omvCodename
declare -l omvInstall=""

forceIpv4="/etc/apt/apt.conf.d/99force-ipv4"
keyserver="hkp://keyserver.ubuntu.com:80"
omvKey="/etc/apt/trusted.gpg.d/openmediavault-archive-keyring.asc"
omvRepo="http://packages.openmediavault.org/public"
omvSources="/etc/apt/sources.list.d/openmediavault.list"
smbOptions="min receivefile size = 16384\ngetwd cache = yes"
url="https://github.com/OpenMediaVault-Plugin-Developers/packages/raw/master/"
vsCodeList="/etc/apt/sources.list.d/vscode.list"

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export LANG="en_US.UTF-8"
export LANGUAGE=en_US:en
export LC_NUMERIC="C"
export LC_CTYPE="C"
export LC_MESSAGES="C"
export LC_ALL="C"

if [ -f /etc/armbian-release ]; then
  . /etc/armbian-release
fi

while getopts "fhi" opt; do
  echo "option ${opt}"
  case "${opt}" in
    f)
      skipFlash=1
      ;;
    h)
      echo "Use the following flags:"
      echo "  -i"
      echo "    enable using IPv6 for apt"
      echo ""
      echo "Examples:"
      echo "  install"
      echo "  install -i"
      exit 100
      ;;
    i)
      ipv6=1
      ;;
    \?)
      echo "Invalid option: -${OPTARG}"
      ;;
  esac
done

# Fix permissions on / if wrong
echo "Current / permissions = $(stat -c %a /)"
chmod g-w,o-w /
echo "New / permissions = $(stat -c %a /)"

# if ipv6 is not enabled, create apt config file to force ipv4
if [ ${ipv6} -ne 1 ]; then
  echo "Forcing IPv4 only for apt..."
  echo 'Acquire::ForceIPv4 "true";' > ${forceIpv4}
fi

echo "Updating repos before installing..."
apt-get --allow-releaseinfo-change update

echo "Installing lsb_release..."
apt-get --yes --no-install-recommends --reinstall install lsb-release

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
    echo "Unsupported version.  Only Debian 10 (Buster) and 11 (Bullseye) are supported.  Exiting..."
    exit 1
  ;;
esac
echo "${omvCodename} :: ${version}"

hostname="raspberrypi"

regex='[a-zA-Z]([-a-zA-Z0-9]{0,61}[a-zA-Z0-9])'
if [[ ! ${hostname} =~ ${regex} ]]; then
    echo "Invalid hostname.  Exiting..."
    exit 6
fi

# Add Debian signing keys to raspbian to prevent apt-get update failures
# when OMV adds security and/or backports repos
if grep -rq raspberrypi.org /etc/apt/*; then
  echo "Adding Debian signing keys..."
  for key in AA8E81B4331F7F50 112695A0E562B32A 04EE7237B7D453EC 648ACFD622F3D138; do
    apt-key adv --no-tty --keyserver ${keyserver} --recv-keys "${key}"
  done
  echo "Installing monit from raspberrypi repo..."
  apt-get --yes --no-install-recommends install -t ${codename} monit

  # remove vscode repo if found since there is no desktop environment
  # empty file will exist to keep raspberrypi-sys-mods package from adding it back
  truncate -s 0 "${vsCodeList}"
fi

echo "Install prerequisites..."
apt-get --yes --no-install-recommends install dirmngr gnupg

# install openmediavault if not installed already
omvInstall=$(dpkg -l | awk '$2 == "openmediavault" { print $1 }')
if [[ ! "${omvInstall}" == "ii" ]]; then
  echo "Installing openmediavault required packages..."
  if ! apt-get --yes --no-install-recommends install postfix; then
    echo "failed installing postfix"
    exit 2
  fi

  echo "Adding openmediavault repo and key..."
  echo "deb ${omvRepo} ${omvCodename} main" > ${omvSources}
  wget -O "${omvKey}" ${omvRepo}/archive.key
  apt-key add "${omvKey}"

  echo "Updating repos..."
  if ! apt-get update; then
    echo "failed to update apt repos."
    exit 2
  fi

  echo "Install openmediavault-keyring..."
  if ! apt-get --yes install openmediavault-keyring; then
    echo "failed to install openmediavault-keyring package."
    exit 2
  fi

  monitInstall=$(dpkg -l | awk '$2 == "monit" { print $1 }')
  if [[ ! "${monitInstall}" == "ii" ]]; then
    if ! apt-get --yes --no-install-recommends install monit; then
      echo "failed installing monit"
      exit 2
    fi
  fi

  echo "Installing openmediavault..."
  aptFlags="--yes --auto-remove --show-upgraded --allow-downgrades --allow-change-held-packages --no-install-recommends"
  cmd="apt-get ${aptFlags} --download-only install openmediavault"
  if ! ${cmd}; then
    echo "failed to install openmediavault package."
    exit 2
  fi

  # install omv-extras
  echo "Downloading omv-extras.org plugin for openmediavault ${version}.x ..."
  file="openmediavault-omvextrasorg_latest_all${version}.deb"

  if [ -f "/${file}" ]; then
    rm /${file}
  fi
  wget ${url}/${file} -P /

fi

# install flashmemory plugin unless disabled
if [ ${skipFlash} -eq 1 ]; then
  echo "Skipping installation of the flashmemory plugin."
else
  echo "Install folder2ram..."
  if apt-get --yes --fix-missing --no-install-recommends --download-only install folder2ram; then
    echo "Installed folder2ram."
  else
    echo "Failed to install folder2ram."
  fi
  echo "Install flashmemory plugin..."
  if apt-get --yes --download-only install openmediavault-flashmemory; then
    echo "Installed flashmemory plugin."
  else
    apt-get --yes --fix-broken install
  fi
fi

exit 0
