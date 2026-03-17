#!/bin/bash -e
#
# debian-trixie-zfs-root.sh
# Improved for Debian 13 (Trixie) 
#

### Static settings
ZPOOL=${TARGET_ZPOOL:-rpool}
TARGETDIST="trixie"

PARTBIOS=${TARGET_PARTBIOS:-1}
PARTEFI=${TARGET_PARTEFI:-2}
PARTZFS=${TARGET_PARTZFS:-3}

SIZESWAP=${TARGET_SIZESWAP:-2G}
SIZETMP=${TARGET_SIZETMP:-3G}
SIZEVARTMP=${TARGET_VARTMP:-3G}

NEWHOST=${TARGET_HOSTNAME}
NEWDNS=${TARGET_DNS:-8.8.8.8 8.8.4.4}

### 1. Identify Disks using Persistent IDs
declare -A BYID
while read -r IDLINK; do
    BYID["$(basename "$(readlink "$IDLINK")")"]="$IDLINK"
done < <(find /dev/disk/by-id/ -type l -not -path "*part*")

for DISK in $(lsblk -I8,254,259 -dn -o name); do
    if [ -n "${BYID[$DISK]}" ]; then
        SELECT+=("$DISK" "${BYID[$DISK]}" off)
    fi
done

TMPFILE=$(mktemp)
whiptail --backtitle "Debian 13 ZFS Installer" --title "Drive selection" --separate-output \
    --checklist "\nSelect drives (Persistent IDs will be used)\n" 20 74 8 "${SELECT[@]}" 2>"$TMPFILE" || exit 1

while read -r DISK; do
    DISKS+=("${BYID[$DISK]}")
    ZFSPARTITIONS+=("${BYID[$DISK]}-part$PARTZFS")
    EFIPARTITIONS+=("${BYID[$DISK]}-part$PARTEFI")
done < "$TMPFILE"

### 2. RAID Level Selection
whiptail --backtitle "$0" --title "RAID level" --separate-output \
    --radiolist "\nSelect ZFS RAID level\n" 20 74 8 \
    "RAID0" "Striped/Single" off \
    "RAID1" "Mirror (RAID10 if n>=4)" on \
    "RAIDZ1" "1-disk parity" off \
    "RAIDZ2" "2-disk parity" off 2>"$TMPFILE" || exit 1

RAIDLEVEL=$(head -n1 "$TMPFILE" | tr '[:upper:]' '[:lower:]')

case "$RAIDLEVEL" in
    raid0) RAIDDEF="${ZFSPARTITIONS[*]}" ;;
    raid1)
        if [ $((${#ZFSPARTITIONS[@]} % 2)) -ne 0 ]; then echo "Need even disks for Mirror" >&2; exit 1; fi
        I=0
        for P in "${ZFSPARTITIONS[@]}"; do
            [ $((I % 2)) -eq 0 ] && RAIDDEF+=" mirror"
            RAIDDEF+=" $P"
            ((I++))
        done
        ;;
    *) RAIDDEF="$RAIDLEVEL ${ZFSPARTITIONS[*]}" ;;
esac

### 3. Preparation & Dependencies
apt-get update
apt-get install -y zfsutils-linux gdisk dosfstools debootstrap

# Ensure hostid is stable
if [ "$(hostid | cut -b-6)" == "007f01" ]; then
    dd if=/dev/urandom of=/etc/hostid bs=1 count=4
fi

### 4. Partitioning
for DISK in "${DISKS[@]}"; do
    sgdisk --zap-all "$DISK"
    sgdisk -a1 -n$PARTBIOS:34:2047  -t$PARTBIOS:EF02 \
               -n$PARTEFI:2048:+512M -t$PARTEFI:EF00 \
               -n$PARTZFS:0:0        -t$PARTZFS:BF01 "$DISK"
done
sleep 2

### 5. Pool Creation (GRUB-Compatible Flags)
# We disable all features and enable only what GRUB understands to prevent boot failure
zpool create -f -o ashift=12 -o altroot=/target -o autotrim=on \
    -d -o feature@async_destroy=enabled \
    -o feature@empty_bpobj=enabled \
    -o feature@filesystem_limits=enabled \
    -o feature@lz4_compress=enabled \
    -o feature@spacemap_histogram=enabled \
    -o feature@extensible_dataset=enabled \
    -o feature@bookmarks=enabled \
    -o feature@enabled_txg=enabled \
    -o feature@hole_birth=enabled \
    -o feature@embedded_data=enabled \
    -o feature@resilver_defer=enabled \
    -O normalization=formD -O relatime=on -O xattr=sa -O acltype=posixacl \
    -O canmount=off -O mountpoint=none "$ZPOOL" $RAIDDEF

# Datasets
zfs create "$ZPOOL/ROOT"
zfs create -o mountpoint=/ "$ZPOOL/ROOT/debian-$TARGETDIST"
zpool set bootfs="$ZPOOL/ROOT/debian-$TARGETDIST" "$ZPOOL"

zfs create -o mountpoint=legacy "$ZPOOL/var"
zfs create -o mountpoint=legacy -o com.sun:auto-snapshot=false -o quota=$SIZEVARTMP "$ZPOOL/var/tmp"
zfs create -V "$SIZESWAP" -b "$(getconf PAGESIZE)" -o compression=off -o logbias=throughput -o sync=always -o primarycache=metadata "$ZPOOL/swap"

# Mounts
mkdir -p /target/var /target/var/tmp
mount -t zfs "$ZPOOL/var" /target/target/var 2>/dev/null || mount -t zfs "$ZPOOL/var" /target/var
mount -t zfs "$ZPOOL/var/tmp" /target/var/tmp
mkswap -f "/dev/zvol/$ZPOOL/swap"

### 6. Debootstrap (Including Firmware)
debootstrap --include=zfs-initramfs,zfsutils-linux,linux-image-amd64,linux-headers-amd64,grub-efi-amd64,firmware-linux-free,firmware-linux-nonfree,locales,nano,curl \
    --components main,contrib,non-free,non-free-firmware "$TARGETDIST" /target http://deb.debian.org/debian/

### 7. System Configuration
test -n "$NEWHOST" || NEWHOST=debian-$(hostid)
echo "$NEWHOST" > /target/etc/hostname
cp /etc/hostid /target/etc/hostid

cat << EOF > /target/etc/fstab
/dev/zvol/$ZPOOL/swap  none  swap  defaults  0  0
$ZPOOL/var             /var  zfs   defaults  0  0
$ZPOOL/var/tmp         /var/tmp zfs defaults 0  0
EOF

# Bind mounts for chroot
for i in /dev /dev/pts /proc /sys /run; do mount --bind "$i" "/target$i"; done

### 8. Bootloader & ZFS Integration
cat << EOF | chroot /target
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="root=ZFS=$ZPOOL\/ROOT\/debian-$TARGETDIST /' /etc/default/grub
update-initramfs -u -k all
EOF

# Install GRUB to all EFI partitions for redundancy
I=0
for EFIPART in "${EFIPARTITIONS[@]}"; do
    mkdosfs -F 32 -n "EFI-$I" "$EFIPART"
    mkdir -p /target/boot/efi
    mount "$EFIPART" /target/boot/efi
    chroot /target grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="Debian-ZFS-$I" --recheck
    echo "PARTUUID=$(blkid -s PARTUUID -o value "$EFIPART") /boot/efi vfat defaults 0 1" >> /target/etc/fstab
    umount /target/boot/efi
    ((I++))
done

# Final cache generation
zpool set cachefile=/etc/zfs/zpool.cache "$ZPOOL"
cp /etc/zfs/zpool.cache /target/etc/zfs/zpool.cache

echo "Installation complete. Set root password now."
chroot /target passwd

sync
echo "Done. You can now reboot."
