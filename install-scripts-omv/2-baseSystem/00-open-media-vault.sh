#!/bin/bash -e

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export LANG="en_US.UTF-8"
export LANGUAGE=en_US:en
export LC_NUMERIC="C"
export LC_CTYPE="C"
export LC_MESSAGES="C"
export LC_ALL="C"

apt-get install -y -q chrony samba nginx-full php-common python3 collectd nfs-kernel-server beep

chmod +x $FILE_FOLDER/install-omv.sh

$FILE_FOLDER/install-omv.sh

# will be called on first boot
install -m 755 $FILE_FOLDER/ufw-init.sh "/usr/local/sbin/ufw-init"
install -m 755 $FILE_FOLDER/install-omv-first-boot.sh "/usr/local/sbin/install-omv-first-boot"
