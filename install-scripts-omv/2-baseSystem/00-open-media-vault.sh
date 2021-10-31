#!/bin/bash -e

chmod +x $FILE_FOLDER/install-omv.sh

$FILE_FOLDER/install-omv.sh

# will be called on first boot
install -m 755 $FILE_FOLDER/ufw-init.sh "/usr/local/sbin/ufw-init"
install -m 755 $FILE_FOLDER/install-omv-first-boot.sh "/usr/local/sbin/install-omv-first-boot"
