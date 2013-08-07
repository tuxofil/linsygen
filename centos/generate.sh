#!/bin/sh

if [ -z "$1" ]; then
    echo "Usage: $0 <config>" 1>&2
    exit 1
fi

set -e
. `readlink --canonicalize "$1"`

## ---------------------------------------------
## cleaning...
if [ -d "$ROOTFS" ]; then
    for F in $FAKES; do
        umount "$ROOTFS"/"$F" || :
    done
    umount "$ROOTFS"/dev || :
    umount "$ROOTFS"/proc || :
    umount "$ROOTFS"/sys || :
    chroot "$ROOTFS" umount -a || :
    umount -f "$ROOTFS" || :
    rmdir "$ROOTFS"
fi
if [ -f $IMG ]; then
    LOOPDEVS=`losetup --associated "$IMG" | sed -E 's/^([^:]+).*$/\1/'`
    for LD in $LOOPDEVS; do
        kpartx -d "$LD" || :
        losetup --detach "$LD"
    done
    rm --force -- "$IMG"
fi
rm --recursive --force -- "$TMPDIR"/fakefs

## ---------------------------------------------
## create disk image and mount it...
mkdir --parents "$TMPDIR"
BYTES=`expr $DISKSIZE '*' 1024 '*' 1024`
dd if=/dev/zero of="$IMG" bs=1 count=1 seek=$(($BYTES - 1)) conv=notrunc
LOOPDEV=`losetup --find`
losetup "$LOOPDEV" "$IMG"
parted --script "$LOOPDEV" mklabel msdos
parted --script "$LOOPDEV" mkpart primary ext2 1 $DISKSIZE
kpartx -a "$LOOPDEV"
LOOPDEV1=/dev/mapper/`basename "$LOOPDEV"`p1
mkfs.ext3 "$LOOPDEV1"
## create the same block devices under the /dev directory
## to make able to install GRUB.
## See GRUB Bug#27737 (http://savannah.gnu.org/bugs/?func=detailitem&item_id=27737)
LOOPDEV_SYM=/dev/sdz
LOOPDEV1_SYM=/dev/sdz1
rm --force -- "$LOOPDEV_SYM" "$LOOPDEV1_SYM"
set `ls -lL "$LOOPDEV" | sed s/,// | awk '{print $5 " " $6}'`
mknod "$LOOPDEV_SYM" b $1 $2
set `ls -lL "$LOOPDEV1" | sed s/,// | awk '{print $5 " " $6}'`
mknod "$LOOPDEV1_SYM" b $1 $2
## mount partition
mkdir --mode=755 --parents "$ROOTFS"
mount "$LOOPDEV1_SYM" "$ROOTFS"

## ---------------------------------------------
## initiating root fs directory...
mkdir --mode=755 --parents "$ROOTFS"/dev
mknod -m 666 "$ROOTFS"/dev/null c 1 3
mknod -m 666 "$ROOTFS"/dev/zero c 1 5
for F in $FAKES; do
    mkdir --parents "$TMPDIR"/fakefs/"$F"
    mkdir --parents "$ROOTFS"/"$F"
    mount "$TMPDIR"/fakefs/"$F" "$ROOTFS"/"$F" -o bind
done
mkdir --parents "$ROOTFS"/var/lib
dd if=/dev/urandom of="$ROOTFS"/var/lib/random-seed bs=1 count=512
mkdir --parents "$ROOTFS"/etc
cat > "$ROOTFS"/etc/fstab << EOF
/dev/sda1  /         ext2    defaults        1 1
tmpfs      /dev/shm  tmpfs   defaults        0 0
devpts     /dev/pts  devpts  gid=5,mode=620  0 0
sysfs      /sys      sysfs   defaults        0 0
proc       /proc     proc    defaults        0 0
EOF

## ---------------------------------------------
## setup release...
mkdir --parents "$ROOTFS"/var/lib/rpm
rpm --root="$ROOTFS" --rebuilddb
rpm --root="$ROOTFS" --install --nodeps "$RELEASE_PACKAGE"

## ---------------------------------------------
## installing packages...
yum \
    --installroot="$ROOTFS" \
    --assumeyes \
    install $PACKAGES

## ---------------------------------------------
## generate ssh key for access to target...
if [ ! -f .ssh/id_rsa ]; then
    mkdir --mode=755 --parents .ssh
    ssh-keygen -t rsa -N "" -q -f .ssh/id_rsa
fi
if [ ! -f .ssh/config ]; then
    cat > .ssh/config <<-EOF
	IdentityFile .ssh/id_rsa
	UserKnownHostsFile .ssh/known_hosts
	StrictHostKeyChecking no
	Host *
	    User root
	EOF
fi

## ---------------------------------------------
## configuring system...
mkdir --parents "$ROOTFS"/root/.ssh
ssh-keygen -t rsa -N "" -q -f "$ROOTFS"/root/.ssh/id_rsa
ssh-keygen -y -q -f .ssh/id_rsa > "$ROOTFS"/root/.ssh/authorized_keys
# to jump between nodes without password:
ssh-keygen -y -q -f "$ROOTFS"/root/.ssh/id_rsa >> "$ROOTFS"/root/.ssh/authorized_keys
# configure and enable rest of essential services:
chroot "$ROOTFS" chkconfig sshd on
# copy custom files...
for CUSTOM in $TARBALLS; do
    tar --extract \
        --file "$CUSTOM" \
        --overwrite \
        --preserve-permissions \
        --same-owner \
        --directory "$ROOTFS"
done

## ---------------------------------------------
## creating initrd...
mount /dev "$ROOTFS"/dev -o bind
# we need mounted /dev to change root password
chroot "$ROOTFS" sh -c "echo '$ROOT_PASSWORD' | passwd --stdin root"
mount /proc "$ROOTFS"/proc -o bind
KERNEL_VERSION=`basename "$ROOTFS"/boot/vmlinuz-* | sed --regexp-extended 's/^[^-]+-//'`
chroot "$ROOTFS" mkinitrd --force -v --rootdev="$LOOPDEV1_SYM" \
    --with=block /boot/initramfs-"$KERNEL_VERSION".img "$KERNEL_VERSION"

## ---------------------------------------------
## configure and install grub...
cat > "$ROOTFS"/boot/grub/grub.conf <<EOF
default=0
timeout=1

title CentOS
  root (hd0,0)
  kernel /vmlinuz ro root=/dev/sda1 rhgb noquiet clocksource_failover
  initrd /initrd
EOF
cp --dereference --verbose --force "$ROOTFS"/boot/vmlinuz-* "$ROOTFS"/vmlinuz
cp --dereference --verbose --force "$ROOTFS"/boot/initramfs-*.img "$ROOTFS"/initrd
cp --dereference --verbose --force "$ROOTFS"/vmlinuz "$ROOTFS"/initrd "$TMPDIR"/
echo "(hd0) $LOOPDEV_SYM" > "$ROOTFS"/boot/grub/device.map
echo "$LOOPDEV1_SYM / ext2 rw 0 0" > "$ROOTFS"/etc/mtab
chroot "$ROOTFS" grub-install "$LOOPDEV_SYM"

## ---------------------------------------------
## umounting target...
sync
chroot "$ROOTFS" umount /proc
umount "$ROOTFS"/dev
umount "$ROOTFS"/sys || :
for F in $FAKES; do
    umount "$ROOTFS"/"$F"
done
umount "$ROOTFS"
rm --force -- "$LOOPDEV_SYM" "$LOOPDEV1_SYM"
kpartx -d "$LOOPDEV"
losetup --detach "$LOOPDEV"

## ---------------------------------------------
## cleaning temporary files...
rmdir "$ROOTFS"
rm --recursive --force -- "$TMPDIR"/fakefs/*
rmdir "$TMPDIR"/fakefs

## ---------------------------------------------
## success
echo "Done"

