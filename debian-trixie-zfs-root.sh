#!/bin/bash
set -e

# --- USER CONFIG ---
NEW_USER="admin"
NEW_HOSTNAME="debian-zfs"
ZPOOL_NAME="rpool"
TARGET_DIST="trixie"

### 1. Nuclear APT Fix & Dependencies
echo "Step 1: Fixing APT and installing ZFS..."
rm -rf /etc/apt/sources.list /etc/apt/sources.list.d/*
cat << EOF > /etc/apt/sources.list
deb http://deb.debian.org/debian/ $TARGET_DIST main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ $TARGET_DIST-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $TARGET_DIST-security main contrib non-free non-free-firmware
EOF

apt-get update
apt-get install -y zfsutils-linux gdisk debootstrap dosfstools sudo network-manager

# Load ZFS - Build if necessary (handles kernel mismatches)
modprobe zfs || { 
    echo "Live kernel mismatch detected. Building ZFS module via DKMS..."
    apt-get install -y linux-headers-$(uname -r) zfs-dkms
    modprobe zfs
}

### 2. Universal Disk Selection
declare -A BYID
SELECT=()
for dev in /dev/disk/by-id/*; do
    [[ "$dev" == *"-part"* ]] && continue
    [ ! -L "$dev" ] && continue
    # Filter out optical drives or strange loopbacks
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
    --checklist "Select disks (NVMe/SATA/VirtIO):" 20 78 10 "${SELECT[@]}" 2>"$TMPFILE" || exit 1

DISKS=()
while read -r D; do DISKS+=("${BYID[$D]}"); done < "$TMPFILE"
[ ${#DISKS[@]} -eq 0 ] && exit 1

### 3. Aligned Partitioning (The Fix)
echo "Step 3: Creating Aligned Partitions..."
for D in "${DISKS[@]}"; do
    sgdisk --zap-all "$D"
    sgdisk --clear "$D"
    
    # 1: BIOS Boot (1MB, starts at 2048 for alignment)
    sgdisk -n 1:0:+1M    -t 1:EF02 -c 1:"BIOSBoot" "$D"
    
    # 2: EFI System (512MB)
    sgdisk -n 2:0:+512M  -t 2:EF00 -c 2:"EFI" "$D"
    
    # 3: ZFS (Remainder)
    sgdisk -n 3:0:0      -t 3:BF01 -c 3:"ZFS" "$D"
done
udevadm settle
sleep 2

### 4. Pool Creation (Drive-Type Aware)
echo "Step 4: Creating Pool..."
ZFS_PARTS=()
for D in "${DISKS[@]}"; do
    # This checks if it's NVMe (p3) or SATA (-part3)
    PART=$(ls "${D}"* | grep -E "(-part3|p3)$" | head -n1)
    ZFS_PARTS+=("$PART")
done

zpool create -f -o ashift=12 -o altroot=/target \
    -O compression=lz4 -O acltype=posixacl -O xattr=sa -O relatime=on \
    -O normalization=formD -O mountpoint=none "$ZPOOL_NAME" "${ZFS_PARTS[@]}"

zfs create -o mountpoint=/ "$ZPOOL_NAME/ROOT"
zpool set bootfs="$ZPOOL_NAME/ROOT" "$ZPOOL_NAME"
mount -t zfs "$ZPOOL_NAME/ROOT" /target

### 5. Debootstrap & Network
echo "Step 5: Installing Base System..."
debootstrap --include=zfs-initramfs,zfsutils-linux,linux-image-amd64,grub-efi-amd64,network-manager,sudo,nano \
    --components main,contrib,non-free,non-free-firmware "$TARGET_DIST" /target http://deb.debian.org/debian/

echo "$NEW_HOSTNAME" > /target/etc/hostname
cp /etc/resolv.conf /target/etc/resolv.conf
cp /etc/hostid /target/etc/hostid

# Auto-detect Network Interface for the new system
IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo' | head -n1)
cat << EOF > /target/etc/network/interfaces
auto lo
iface lo inet loopback
allow-hotplug $IFACE
iface $IFACE inet dhcp
EOF

### 6. Chroot Configuration
for i in /dev /dev/pts /proc /sys /run; do mount --bind "$i" "/target$i"; done

chroot /target bash -c "
useradd -m -s /bin/bash $NEW_USER
echo '$NEW_USER ALL=(ALL) ALL' > /etc/sudoers.d/$NEW_USER
chmod 0440 /etc/sudoers.d/$NEW_USER
echo 'zfs_import_dir=\"/dev/disk/by-id\"' >> /etc/default/zfs
update-initramfs -u -k all
update-grub
"

### 7. Multi-Disk EFI Install
for D in "${DISKS[@]}"; do
    EFIPART=$(ls "${D}"* | grep -E "(-part2|p2)$" | head -n1)
    mkdosfs -F 32 "$EFIPART"
    mkdir -p /target/boot/efi
    mount "$EFIPART" /target/boot/efi
    chroot /target grub-install --target=x86_64-efi --efi-directory=/boot/efi --recheck
    umount /target/boot/efi
done

echo "INSTALL SUCCESSFUL!"
echo "Set password for $NEW_USER:"
chroot /target passwd "$NEW_USER"
echo "Set password for ROOT:"
chroot /target passwd root

sync
echo "Done. You can now reboot."
