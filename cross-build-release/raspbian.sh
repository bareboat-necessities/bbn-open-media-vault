#!/bin/bash -xe
{
  source lib.sh

  MY_CPU_ARCH=$1
  LYSMARINE_VER=$2

  thisArch="raspios"
  cpuArch="armhf"
  if [ "arm64" == "$MY_CPU_ARCH" ]; then
    cpuArch="arm64"
  fi

  zipName="raspios_lite_${cpuArch}_latest"
  imageSource="https://downloads.raspberrypi.org/${zipName}"

  checkRoot

  # Create caching folder hierarchy to work with this architecture.
  setupWorkSpace $thisArch

  # Download the official image
  log "Downloading official image from internet."
  myCache=./cache/$thisArch

{
  echo curl -k -L --range 0-999999999           -o $myCache/image.part1 $imageSource
  echo curl -k -L --range 1000000000-1999999999 -o $myCache/image.part2 $imageSource
  echo curl -k -L --range 2000000000-           -o $myCache/image.part3 $imageSource
} | xargs -L 1 -I CMD -P 3 bash -c CMD

  cat $myCache/image.part? > $myCache/$zipName
  rm $myCache/image.part?
  7z e -o$myCache/ $myCache/$zipName
  rm $myCache/$zipName

  # Copy image file to work folder add temporary space to it.
  imageName=$(
    cd $myCache
    ls *.img
    cd ../../
  )
  inflateImage $thisArch $myCache/$imageName

  # copy ready image from cache to the work dir
  cp -fv $myCache/$imageName-inflated ./work/$thisArch/$imageName

  # Mount the image and make the binds required to chroot.
  mountImageFile $thisArch ./work/$thisArch/$imageName

  # Copy the lysmarine and origine OS config files in the mounted rootfs
  addLysmarineScripts $thisArch

  mkRoot=work/${thisArch}/rootfs
  ls -l $mkRoot

  mkdir -p ./cache/${thisArch}/stageCache
  mkdir -p $mkRoot/install-scripts-omv/stageCache
  mkdir -p /run/shm
  mkdir -p $mkRoot/run/shm
  mount -o bind /etc/resolv.conf $mkRoot/etc/resolv.conf
  mount -o bind /dev $mkRoot/dev
  mount -o bind /sys $mkRoot/sys
  mount -o bind /proc $mkRoot/proc
  mount -o bind /tmp $mkRoot/tmp
  mount --rbind $myCache/stageCache $mkRoot/install-scripts-omv/stageCache
  mount --rbind /run/shm $mkRoot/run/shm
  chroot $mkRoot /bin/bash -xe <<EOF
    set -x; set -e; cd /install-scripts-omv; export LMBUILD="raspios"; ls; chmod +x *.sh; ./install.sh 0 2 a; exit
EOF

  # Unmount
  umountImageFile $thisArch ./work/$thisArch/$imageName

  ls -l ./work/$thisArch/$imageName
  wget "https://raw.githubusercontent.com/Drewsif/PiShrink/master/pishrink.sh" -P $myCache/
  chmod +x "$myCache"/pishrink.sh
  "$myCache"/pishrink.sh -s ./work/$thisArch/$imageName || if [ $? == 11 ]; then
    log "Image already shrunk to smallest size"
  fi
  ls -l ./work/$thisArch/$imageName

  # Renaming the OS and moving it to the release folder.
  cp -v ./work/$thisArch/$imageName ./release/$thisArch/lysmarine-bbn-omv-iot_${LYSMARINE_VER}-${thisArch}-${cpuArch}.img

  exit 0
}
