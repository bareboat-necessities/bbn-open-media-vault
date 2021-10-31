#!/bin/bash -e

apt-get -y autoremove
apt-get clean
#npm cache clean --force

# remove python pip cache
rm -rf ~/.cache/pip

# remove all cache
rm -rf ~/.cache
rm -rf ~/.config
rm -rf ~/.npm
rm -rf ~/.wget*
rm -rf $(find /var/log/ -type f)

echo "Installing openmediavault..."
aptFlags="--yes --auto-remove --show-upgraded --allow-downgrades --allow-change-held-packages --no-install-recommends"
cmd="apt-get ${aptFlags} --download-only install openmediavault"
if ! ${cmd}; then
  echo "failed to install openmediavault package."
  exit 2
fi

# install flashmemory plugin unless disabled
declare -i skipFlash=0

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

date --rfc-3339=seconds > /etc/bbn-omv-build
fake-hwclock save
