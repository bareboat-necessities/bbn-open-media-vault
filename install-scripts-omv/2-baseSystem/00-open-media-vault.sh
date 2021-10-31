#!/bin/bash -e

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export LANG="en_US.UTF-8"
export LANGUAGE=en_US:en
export LC_NUMERIC="C"
export LC_CTYPE="C"
export LC_MESSAGES="C"
export LC_ALL="C"

echo "samba-common samba-common/workgroup string WORKGROUP" | sudo debconf-set-selections
echo "samba-common samba-common/dhcp boolean true" | sudo debconf-set-selections
echo "samba-common samba-common/do_debconf boolean true" | sudo debconf-set-selections

apt-get install -y -q chrony samba nginx-full php-common python3 collectd nfs-kernel-server beep

install -m 755 -d -o root -g adm "/var/log/samba"

chmod +x $FILE_FOLDER/install-omv.sh

$FILE_FOLDER/install-omv.sh

# will be called on first boot
install -m 755 $FILE_FOLDER/ufw-init.sh "/usr/local/sbin/ufw-init"
install -m 755 $FILE_FOLDER/install-omv-first-boot.sh "/usr/local/sbin/install-omv-first-boot"
