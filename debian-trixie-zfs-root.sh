#!/bin/bash
set -e

# --- CONFIGURATION ---
NEW_USER="admin"
NEW_HOSTNAME="debian-zfs"
TARGET_DIST="trixie"

### 1. Prepare Environment
echo "Step 1: Setting up repositories and installing ZFS..."
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
echo "deb http://deb.debian.org/debian $TARGET_DIST main contrib non-free-firmware" > /etc/apt/sources.list
apt update
apt install --yes debootstrap gdisk zfsutils-linux linux-headers-generic
modprobe zfs

### 2. Disk Selection
declare -A BYID
SELECT=()
for dev in /dev/disk/by-id/*; do
    [[ "$dev" == *"-part"* ]] && continue
    [ ! -L "$dev" ] && continue
    REAL=$(basename "$(readlink -f "$dev")")
    [[ "$REAL" == loop* ]] && continue
    if [[ -z "${BYID[$REAL]}" ]]; then
        BYID["$REAL"]="$dev"
        SIZE=$(lsblk -dn -o SIZE "/dev/$REAL")
        SELECT+=("$REAL" "$dev ($SIZE)" off)
    fi
done
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
whiptail --title "ZFS Drive Selection" --separate-output \
    --checklist "Select disks:" 20 78 10 "${SELECT[@]}" 2>"$TMPFILE" || exit 1
DISKS=()
while read -r D; do DISKS+=("${BYID[$D]}"); done < "$TMPFILE"

### 3. Disk Formatting
echo "Step 3: Partitioning disks..."
for D in "${DISKS[@]}"; do
    sgdisk --zap-all "$D"
    sgdisk -a1 -n1:24K:+1000K -t1:EF02 "$D"
    sgdisk -n2:1M:+512M -t2:EF00 "$D"
    sgdisk -n3:0:+1G -t3:BF01 "$D"
    sgdisk -n4:0:0 -t4:BF00 "$D"
done
udevadm settle && sleep 2

### 4. Pool & Dataset Creation
echo "Step 4: Creating pools and datasets..."
zpool create -o ashift=12 -o autotrim=on -o compatibility=grub2 \
    -O devices=off -O acltype=posixacl -O xattr=sa -O compression=lz4 \
    -O normalization=formD -O relatime=on -O canmount=off \
    -O mountpoint=/boot -R /mnt bpool "${DISKS[@]/%/-part3}"

zpool create -f -o ashift=12 -o autotrim=on \
    -O acltype=posixacl -O xattr=sa -O dnodesize=auto -O compression=lz4 \
    -O normalization=formD -O relatime=on -O canmount=off \
    -O mountpoint=/ -R /mnt rpool "${DISKS[@]/%/-part4}"

zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o canmount=off -o mountpoint=none bpool/BOOT
zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/debian
zfs mount rpool/ROOT/debian
zfs create -o mountpoint=/boot bpool/BOOT/debian

# Standard Datasets
zfs create rpool/home
zfs create -o mountpoint=/root rpool/home/root
zfs create -o canmount=off rpool/var
zfs create rpool/var/log
zfs create rpool/var/spool
zfs create -o com.sun:auto-snapshot=false rpool/var/cache

### 5. System Installation
echo "Step 5: Bootstrapping base system + SSH..."
debootstrap --include=openssh-server,unattended-upgrades,apt-listchanges,sudo,nano "$TARGET_DIST" /mnt

# Create the ZFS config directory before copying the cache
mkdir -p /mnt/etc/zfs
cp /etc/zfs/zpool.cache /mnt/etc/zfs/

echo "$NEW_HOSTNAME" > /mnt/etc/hostname
cp /etc/resolv.conf /mnt/etc/resolv.conf

### 6. System Configuration (Chroot)
mount --make-private --rbind /dev  /mnt/dev
mount --make-private --rbind /proc /mnt/proc
mount --make-private --rbind /sys  /mnt/sys

chroot /mnt bash --login <<EOF
apt update
apt install --yes console-setup locales
apt install --yes linux-headers-generic linux-image-generic zfs-initramfs

# GRUB & EFI
apt install --yes dosfstools grub-efi-amd64 shim-signed
# Note: Installing EFI to the first selected disk
mkdosfs -F 32 -s 1 -n EFI ${DISKS[0]}-part2
mkdir -p /boot/efi
mount ${DISKS[0]}-part2 /boot/efi
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck --no-floppy

# Fix ZFS Boot
echo 'REMAKE_INITRD=yes' > /etc/dkms/zfs.conf
sed -i 's|GRUB_CMDLINE_LINUX=""|GRUB_CMDLINE_LINUX="root=ZFS=rpool/ROOT/debian"|' /etc/default/grub
update-grub

# Enable Unattended Upgrades for security
cat <<EOP > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOP

# User setup
useradd -m -s /bin/bash $NEW_USER
usermod -a -G sudo,netdev $NEW_USER
EOF

echo "------------------------------------------------"
echo "Set password for $NEW_USER:"
chroot /mnt passwd $NEW_USER
echo "Set password for ROOT:"
chroot /mnt passwd root
echo "------------------------------------------------"

### 7. Cleanup
zpool export -a
echo "Done! You can now reboot into your new ZFS system."
