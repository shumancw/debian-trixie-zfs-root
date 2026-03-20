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
apt install --yes debootstrap gdisk zfsutils-linux linux-headers-generic [cite: 70, 84, 86]
modprobe zfs [cite: 85]

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
while read -r D; do DISKS+=("${BYID[$D]}"); done < "$TMPFILE" [cite: 89, 90]

### 3. Disk Formatting
echo "Step 3: Partitioning disks..."
for D in "${DISKS[@]}"; do
    sgdisk --zap-all "$D" [cite: 117]
    sgdisk -a1 -n1:24K:+1000K -t1:EF02 "$D" [cite: 123]
    sgdisk -n2:1M:+512M -t2:EF00 "$D" [cite: 126, 127]
    sgdisk -n3:0:+1G -t3:BF01 "$D" [cite: 130, 131]
    sgdisk -n4:0:0 -t4:BF00 "$D" [cite: 135, 136]
done
udevadm settle && sleep 2

### 4. Pool & Dataset Creation
echo "Step 4: Creating pools and datasets..."
zpool create -o ashift=12 -o autotrim=on -o compatibility=grub2 \
    -O devices=off -O acltype=posixacl -O xattr=sa -O compression=lz4 \
    -O normalization=formD -O relatime=on -O canmount=off \
    -O mountpoint=/boot -R /mnt bpool "${DISKS[@]/%/-part3}" [cite: 143-153]

zpool create -f -o ashift=12 -o autotrim=on \
    -O acltype=posixacl -O xattr=sa -O dnodesize=auto -O compression=lz4 \
    -O normalization=formD -O relatime=on -O canmount=off \
    -O mountpoint=/ -R /mnt rpool "${DISKS[@]/%/-part4}" [cite: 170-177]

zfs create -o canmount=off -o mountpoint=none rpool/ROOT [cite: 237]
zfs create -o canmount=off -o mountpoint=none bpool/BOOT [cite: 238]
zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/debian [cite: 244]
zfs mount rpool/ROOT/debian [cite: 244]
zfs create -o mountpoint=/boot bpool/BOOT/debian [cite: 245]

# Standard Datasets
zfs create rpool/home [cite: 250]
zfs create -o mountpoint=/root rpool/home/root [cite: 251]
zfs create -o canmount=off rpool/var [cite: 253]
zfs create rpool/var/log [cite: 258]
zfs create rpool/var/spool [cite: 260]
zfs create -o com.sun:auto-snapshot=false rpool/var/cache [cite: 262]

### 5. System Installation
echo "Step 5: Bootstrapping base system + SSH..."
debootstrap --include=openssh-server,unattended-upgrades,apt-listchanges,sudo,nano "$TARGET_DIST" /mnt [cite: 267]

# FIX: Create the directory before copying the cache
mkdir -p /mnt/etc/zfs 
cp /etc/zfs/zpool.cache /mnt/etc/zfs/ 

echo "$NEW_HOSTNAME" > /mnt/etc/hostname [cite: 270]
cp /etc/resolv.conf /mnt/etc/resolv.conf [cite: 67]

### 6. System Configuration (Chroot)
mount --make-private --rbind /dev  /mnt/dev [cite: 274]
mount --make-private --rbind /proc /mnt/proc [cite: 274]
mount --make-private --rbind /sys  /mnt/sys [cite: 274]

chroot /mnt bash --login <<EOF
apt update
apt install --yes console-setup locales [cite: 275]
apt install --yes linux-headers-generic linux-image-generic zfs-initramfs [cite: 276]

# GRUB & EFI
apt install --yes dosfstools grub-efi-amd64 shim-signed [cite: 281]
mkdosfs -F 32 -s 1 -n EFI ${DISKS[0]}-part2 [cite: 281]
mkdir -p /boot/efi [cite: 281]
mount ${DISKS[0]}-part2 /boot/efi [cite: 281]
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck --no-floppy [cite: 307]

# Fix ZFS Boot
echo 'REMAKE_INITRD=yes' > /etc/dkms/zfs.conf [cite: 276]
sed -i 's|GRUB_CMDLINE_LINUX=""|GRUB_CMDLINE_LINUX="root=ZFS=rpool/ROOT/debian"|' /etc/default/grub [cite: 302]
update-grub [cite: 304]

# Enable Unattended Upgrades
cat <<EOP > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOP

# User setup
useradd -m -s /bin/bash $NEW_USER [cite: 323]
usermod -a -G sudo,netdev $NEW_USER [cite: 323]
EOF

echo "------------------------------------------------"
echo "Set password for $NEW_USER:"
chroot /mnt passwd $NEW_USER [cite: 323]
echo "Set password for ROOT:"
chroot /mnt passwd root [cite: 285]
echo "------------------------------------------------"

### 7. Cleanup
zpool export -a [cite: 320]
echo "Done! You can now reboot into your new ZFS system."
