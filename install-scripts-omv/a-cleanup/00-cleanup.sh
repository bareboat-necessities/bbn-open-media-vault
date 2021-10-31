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

date --rfc-3339=seconds > /etc/bbn-omv-build
fake-hwclock save
