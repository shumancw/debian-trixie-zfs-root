#!/bin/bash
# debian-trixie-zfs-root.sh (Revision 3 - 2026 Stable)
set -e

### 0. Fix Repositories (DEB822 Support)
echo "Configuring repositories for Debian 13 (Trixie)..."
if [ -f /etc/apt/sources.list.d/debian.sources ]; then
    sed -i 's/Components: main/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources
else
    # Fallback for older ISOs using legacy format
    sed -i 's/main$/main contrib non-free non-free-firmware/' /etc/apt/sources.list
fi

apt-get update

### 1. Preparation & Kernel Check
echo "Installing dependencies..."
apt-get install -y zfsutils-linux gdisk dosfstools debootstrap

# Check if ZFS module can load; if not, compile it for the Live Kernel
if ! modprobe zfs; then
    echo "Standard ZFS module failed to load. Attempting DKMS build for current kernel..."
    apt-get install -y linux-headers-$(uname -r) zfs-dkms
    modprobe zfs
fi

### 2. Identify Disks
declare -A BYID
SELECT=()
for dev in /dev/disk/by-id/*; do
    [[ "$dev" == *"-part"* ]] && continue
    [ ! -L "$dev" ] && continue
    REALNAME=$(basename "$(readlink -f "$dev")")
    if [[ -z "${BYID[$REALNAME]}" ]]; then
        BYID["$REALNAME"]="$dev"
        SIZE=$(lsblk -dn -o SIZE "/dev/$REALNAME")
        SELECT+=("$REALNAME" "$dev ($SIZE)" off)
    fi
done

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

whiptail --title "Drive selection" --separate-output \
    --checklist "Select drives for the ZFS pool:" 20 78 10 "${SELECT[@]}" 2>"$TMPFILE" || exit 1

DISKS=()
ZFSPARTITIONS=()
EFIPARTITIONS=()
while read -r DISK; do
    ID_PATH="${BYID[$DISK]}"
    DISKS+=("$ID_PATH")
    ZFSPARTITIONS+=("${ID_PATH}-part3")
    EFIPARTITIONS+=("${ID_PATH}-part2")
done < "$TMPFILE"

[ ${#DISKS[@]} -eq 0 ] && { echo "No disks selected."; exit 1; }

### 3. RAID Level
whiptail --title "RAID Level" --separate-output \
    --radiolist "Select ZFS RAID level" 20 74 8 \
    "SINGLE" "Stripe (1+ disks)" on \
    "MIRROR" "Mirror (2, 4, 6 disks)" off \
    "RAIDZ1" "RAIDZ1 (3+ disks)" off 2>"$TMPFILE" || exit 1

RAIDTYPE=$(cat "$TMPFILE")
RAIDDEF=""
case "$RAIDTYPE" in
    SINGLE) RAIDDEF="${ZFSPARTITIONS[*]}" ;;
    MIRROR) 
        for ((i=0; i<${#ZFSPARTITIONS[@]}; i+=2)); do RAIDDEF+=" mirror ${ZFSPARTITIONS[i]} ${ZFSPARTITIONS[i+1]}"; done ;;
    RAIDZ1) RAIDDEF="raidz1 ${ZFSPARTITIONS[*]}" ;;
esac

### 4. Partition & Pool
ZPOOL="rpool"
for DISK in "${DISKS[@]}"; do
    sgdisk --zap-all "$DISK"
    sgdisk -n 1:34:2047 -t 1:EF02 -n 2:2048:+512M -t 2:EF00 -n 3:0:0 -t 3:BF01 "$DISK"
done
udevadm settle

zpool create -f -o ashift=12 -o altroot=/target -o autotrim=on \
    -O normalization=formD -O relatime=on -O xattr=sa -O acltype=posixacl \
    -O canmount=off -O mountpoint=none "$ZPOOL" $RAIDDEF

zfs create "$ZPOOL/ROOT"
zfs create -o mountpoint=/ "$ZPOOL/ROOT/debian-trixie"
zpool set bootfs="$ZPOOL/ROOT/debian-trixie" "$ZPOOL"

# Mount & Bootstrap
mount -t zfs "$ZPOOL/ROOT/debian-trixie" /target
debootstrap --include=zfs-initramfs,zfsutils-linux,linux-image-amd64,grub-efi-amd64 \
    --components main,contrib,non-free,non-free-firmware trixie /target http://deb.debian.org/debian/

# Finalize
for i in /dev /dev/pts /proc /sys /run; do mount --bind "$i" "/target$i"; done
cp /etc/hostid /target/etc/hostid

chroot /target bash -c "
update-initramfs -u -k all
update-grub
"

# Install GRUB to EFI
for EFIPART in "${EFIPARTITIONS[@]}"; do
    mkdosfs -F 32 "$EFIPART"
    mount "$EFIPART" /target/boot/efi
    chroot /target grub-install --target=x86_64-efi --efi-directory=/boot/efi --recheck
    umount /target/boot/efi
done

echo "Success. Set root password:"
chroot /target passwd
