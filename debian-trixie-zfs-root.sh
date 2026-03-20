#!/bin/bash
# debian-trixie-zfs-root.sh
# Improved for Debian 13 (Trixie)

# Exit on error, but we'll handle whiptail exits manually for better UX
set -e

### Static settings
ZPOOL="${TARGET_ZPOOL:-rpool}"
TARGETDIST="trixie"

PARTBIOS=1
PARTEFI=2
PARTZFS=3

SIZESWAP="${TARGET_SIZESWAP:-2G}"
SIZEVARTMP="${TARGET_VARTMP:-3G}"
NEWHOST="${TARGET_HOSTNAME:-debian-zfs}"

### 1. Identify Disks (Improved lookup)
declare -A BYID
SELECT=()

# Find all disk devices and map them to their /dev/disk/by-id/ names
for dev in /dev/disk/by-id/*; do
    # Skip partitions and non-symbolic links
    [[ "$dev" == *"-part"* ]] && continue
    [ ! -L "$dev" ] && continue
    
    REALNAME=$(basename "$(readlink -f "$dev")")
    # Only use the first ID found for a physical disk (prefer wwn or scsi over ata)
    if [[ -z "${BYID[$REALNAME]}" ]]; then
        BYID["$REALNAME"]="$dev"
        SIZE=$(lsblk -dn -o SIZE "/dev/$REALNAME")
        SELECT+=("$REALNAME" "$dev ($SIZE)" off)
    fi
done

if [ ${#SELECT[@]} -eq 0 ]; then
    echo "Error: No disks found in /dev/disk/by-id/" >&2
    exit 1
fi

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

whiptail --backtitle "Debian 13 ZFS Installer" --title "Drive selection" --separate-output \
    --checklist "\nSelect drives for the ZFS pool:\n" 20 78 10 "${SELECT[@]}" 2>"$TMPFILE" || exit 1

DISKS=()
ZFSPARTITIONS=()
EFIPARTITIONS=()

while read -r DISK; do
    ID_PATH="${BYID[$DISK]}"
    DISKS+=("$ID_PATH")
    ZFSPARTITIONS+=("${ID_PATH}-part$PARTZFS")
    EFIPARTITIONS+=("${ID_PATH}-part$PARTEFI")
done < "$TMPFILE"

if [ ${#DISKS[@]} -eq 0 ]; then
    echo "No disks selected. Exiting."
    exit 1
fi

### 2. RAID Level Selection
whiptail --backtitle "RAID Config" --title "RAID level" --separate-output \
    --radiolist "\nSelect ZFS RAID level\n" 20 74 8 \
    "SINGLE" "Single disk or striped (RAID0)" on \
    "MIRROR" "Mirror (RAID1 / RAID10)" off \
    "RAIDZ1" "1-disk parity" off \
    "RAIDZ2" "2-disk parity" off 2>"$TMPFILE" || exit 1

RAIDTYPE=$(cat "$TMPFILE")
RAIDDEF=""

case "$RAIDTYPE" in
    SINGLE)
        RAIDDEF="${ZFSPARTITIONS[*]}"
        ;;
    MIRROR)
        if [ $(( ${#ZFSPARTITIONS[@]} % 2 )) -ne 0 ]; then
            echo "Error: Mirror/RAID10 requires an even number of disks." >&2
            exit 1
        fi
        # Group into pairs
        for ((i=0; i<${#ZFSPARTITIONS[@]}; i+=2)); do
            RAIDDEF+=" mirror ${ZFSPARTITIONS[i]} ${ZFSPARTITIONS[i+1]}"
        done
        ;;
    RAIDZ1|RAIDZ2)
        RAIDDEF="${RAIDTYPE,,} ${ZFSPARTITIONS[*]}"
        ;;
esac

### 3. Preparation
apt-get update
apt-get install -y zfsutils-linux gdisk dosfstools debootstrap

# Stabilize HostID
if [ "$(hostid | cut -b-6)" == "007f01" ]; then
    dd if=/dev/urandom of=/etc/hostid bs=1 count=4
fi

### 4. Partitioning
for DISK in "${DISKS[@]}"; do
    sgdisk --zap-all "$DISK"
    sgdisk -n $PARTBIOS:34:2047  -t $PARTBIOS:EF02 \
           -n $PARTEFI:2048:+512M -t $PARTEFI:EF00 \
           -n $PARTZFS:0:0        -t $PARTZFS:BF01 "$DISK"
done
sleep 2
udevadm settle

### 5. Pool & Dataset Creation
# Note: Using standard GRUB-compatible feature set
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

zfs create "$ZPOOL/ROOT"
zfs create -o mountpoint=/ "$ZPOOL/ROOT/debian-$TARGETDIST"
zpool set bootfs="$ZPOOL/ROOT/debian-$TARGETDIST" "$ZPOOL"

zfs create -o mountpoint=legacy "$ZPOOL/var"
zfs create -o mountpoint=legacy -o com.sun:auto-snapshot=false -o quota="$SIZEVARTMP" "$ZPOOL/var/tmp"
zfs create -V "$SIZESWAP" -b $(getconf PAGESIZE) -o compression=off -o logbias=throughput -o sync=always -o primarycache=metadata "$ZPOOL/swap"

# Mount structure
mkdir -p /target
mount -t zfs "$ZPOOL/ROOT/debian-$TARGETDIST" /target
mkdir -p /target/var /target/var/tmp
mount -t zfs "$ZPOOL/var" /target/var
mount -t zfs "$ZPOOL/var/tmp" /target/var/tmp
mkswap -f "/dev/zvol/$ZPOOL/swap"

### 6. Debootstrap
debootstrap --include=zfs-initramfs,zfsutils-linux,linux-image-amd64,grub-efi-amd64,locales,nano \
    --components main,contrib,non-free,non-free-firmware "$TARGETDIST" /target http://deb.debian.org/debian/

### 7. Configuration
echo "$NEWHOST" > /target/etc/hostname
cp /etc/hostid /target/etc/hostid

cat << EOF > /target/etc/fstab
/dev/zvol/$ZPOOL/swap  none  swap  defaults  0  0
$ZPOOL/var             /var  zfs   defaults  0  0
$ZPOOL/var/tmp         /var/tmp zfs defaults 0  0
EOF

for i in /dev /dev/pts /proc /sys /run; do mount --bind "$i" "/target$i"; done

### 8. Bootloader
chroot /target bash -c "
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"root=ZFS=$ZPOOL\/ROOT\/debian-$TARGETDIST /' /etc/default/grub
update-initramfs -u -k all
"

# EFI Setup for all selected disks
for i in "${!EFIPARTITIONS[@]}"; do
    EFIPART="${EFIPARTITIONS[$i]}"
    mkdosfs -F 32 -n "EFI-$i" "$EFIPART"
    mkdir -p /target/boot/efi
    mount "$EFIPART" /target/boot/efi
    chroot /target grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="Debian-ZFS-$i" --recheck
    echo "PARTUUID=$(blkid -s PARTUUID -o value "$EFIPART") /boot/efi vfat defaults 0 1" >> /target/etc/fstab
    umount /target/boot/efi
done

zpool set cachefile=/etc/zfs/zpool.cache "$ZPOOL"
cp /etc/zfs/zpool.cache /target/etc/zfs/zpool.cache

echo "Installation complete. Please set the root password."
chroot /target passwd

sync
echo "Done. Unmount /target and reboot."
