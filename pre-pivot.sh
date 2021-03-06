#!/bin/bash

set -o pipefail

bootdisk() {
    UUID=$({ read -r -n 1 -d '' _; read -n 72 uuid; echo -n ${uuid,,}; } < /sys/firmware/efi/efivars/LoaderDevicePartUUID-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f)

    [[ $UUID ]] || return 1
    echo "/dev/disk/by-partuuid/$UUID"
    return 0
}

get_disk() {
    for dev in /dev/disk/by-path/*; do
        [[ $dev -ef $1 ]] || continue
        echo ${dev%-part*}
        return 0
    done
    return 1
}

udevadm settle

BOOTDISK=$(get_disk $(bootdisk))
[[ $BOOTDISK ]] || die "No boot disk found"

unset FOUND
for swapdev in $BOOTDISK-part*; do
    [[ $(blkid -o value -s PARTLABEL "$swapdev") == "swap" ]] || continue
    FOUND=1
    break
done

if [[ $FOUND ]]; then
    if cryptsetup isLuks --type luks2 "$swapdev"; then
        luksname=swap
        luksdev=/dev/mapper/$luksname

        if ! cryptsetup luksDump "$swapdev" | grep -F -q clevis ; then
            export TPM2TOOLS_TCTI_NAME=device
            export TPM2TOOLS_DEVICE_FILE=/dev/tpmrm0

            if echo -n "zero key" | clevis-luks-bind -f -k - -d "$swapdev" tpm2 '{"pcr_ids":"7"}' 2>&1 | vwarn; then
                clevis-luks-unlock -d "$swapdev" -n "$luksname" || die "Failed to unlock $swapdev"
                echo -n "zero key" | cryptsetup luksRemoveKey "$swapdev" /dev/stdin || die "Failed to remove key from LUKS"
            elif echo -n "zero key" | clevis-luks-bind -f -k - -d "$swapdev" tpm2 '{"pcr_ids":"7","key":"rsa"}' 2>&1 | vwarn; then
                clevis-luks-unlock -d "$swapdev" -n "$luksname" || die "Failed to unlock $swapdev"
                echo -n "zero key" | cryptsetup luksRemoveKey "$swapdev" /dev/stdin || die "Failed to remove key from LUKS"
            else
                warn "Failed to bind swap disk to TPM2"
            fi
        else
            clevis-luks-unlock -d "$swapdev" -n "$luksname"  2>&1 | vinfo || die "Failed to unlock $swapdev"
        fi
        swapdev="$luksdev"
    fi

    swaptype=$(blkid -o value -s TYPE "$swapdev")
    [[ $swaptype == "swsuspend" ]] && \
        /usr/lib/systemd/systemd-hibernate-resume "$swapdev"  &>/dev/null

    [[ $swaptype != "swap" ]] && \
        mkswap "$swapdev" 2>&1 | vinfo

    swapon "$swapdev" 2>&1 | vinfo
fi


unset FOUND
for datadev in $BOOTDISK-part*; do
    [[ $(blkid -o value -s PARTLABEL "$datadev") == "data" ]] || continue
    FOUND=1
    break
done
[[ $FOUND ]] || die "No data disk found"

if cryptsetup isLuks --type luks2 "$datadev"; then
    #luksname=luks-$(blkid -o value -s UUID "$datadev")
    luksname=data
    luksdev=/dev/mapper/$luksname

    if ! [[ -b $luksdev ]]; then
        if ! cryptsetup luksDump "$datadev" | grep -F -q clevis ; then
            export TPM2TOOLS_TCTI_NAME=device
            export TPM2TOOLS_DEVICE_FILE=/dev/tpmrm0

            if echo -n "zero key" | clevis-luks-bind -f -k - -d "$datadev" tpm2 '{"pcr_ids":"7"}'; then
                clevis-luks-unlock -d "$datadev" -n "$luksname" || die "Failed to unlock $datadev"
            elif echo -n "zero key" | clevis-luks-bind -f -k - -d "$datadev" tpm2 '{"pcr_ids":"7","key":"rsa"}'; then
                clevis-luks-unlock -d "$datadev" -n "$luksname" || die "Failed to unlock $datadev"
            else
                warn "Failed to bind disk to TPM2"
                echo -n "zero key" | cryptsetup open --type luks2 "$datadev" $luksname --key-file /dev/stdin
            fi
        else
            clevis-luks-unlock -d "$datadev" -n "$luksname" || die "Failed to unlock $datadev"
        fi
        tpm2_pcrextend \
            -T device:/dev/tpmrm0 \
            7:sha1=f6196dd72e7fad01051cb171ed3e8a29f7217b3a,sha256=6064ec4f91ea49cce638d0b7f9013989c01cba8a62957ac96cd1976bb2e098fa 2>&1 \
            || die "Failed to extend PCR7"
    fi
    datadev="$luksdev"
fi

if [[ $(blkid -o value -s TYPE "$datadev") != "xfs" ]]; then
    mkfs.xfs -f -L data "$datadev"
fi

mkdir -p /run/initramfs/mnt

mount -o discard $datadev /run/initramfs/mnt || die "Failed to mount $datadev"

for i in var home cfg local; do
    if ! [[ -d /run/initramfs/mnt/$i ]]; then
        mkdir /run/initramfs/mnt/$i
        FIRST_TIME=1
    elif [[ -f /run/initramfs/mnt/$i/.autorelabel ]]; then
        RELABEL=1
    fi
done

mount -o bind /run/initramfs/mnt/var   /sysroot/var
mount -o bind /run/initramfs/mnt/home  /sysroot/home
mount -o bind /run/initramfs/mnt/cfg   /sysroot/cfg
mount -o bind /run/initramfs/mnt/local /sysroot/usr/local
umount -l /run/initramfs/mnt &>/dev/null

if [[ $FIRST_TIME ]]; then
    ln -fs ../run /sysroot/var/run
    ln -fs ../run/lock /sysroot/var/lock

    mount -o bind /sys /sysroot/sys
    mount -t selinuxfs none /sysroot/sys/fs/selinux

#    if [ -f /etc/machine-id ]; then
#        cp /etc/machine-id /sysroot/cfg/machine-id
#    else
#        R=$(</proc/sys/kernel/random/uuid)
#        echo ${R//-} >/sysroot/cfg/machine-id
#    fi

    chroot /sysroot bash -c '
        /usr/sbin/load_policy -i
        /usr/sbin/setfiles -m -F -v \
            /etc/selinux/targeted/contexts/files/file_contexts \
            /cfg /var /home /usr/local
    ' &> /dev/null

    umount /sysroot/sys/fs/selinux
    umount /sysroot/sys
fi

if [[ $RELABEL ]]; then
    mount -o bind /sys /sysroot/sys
    mount -t selinuxfs none /sysroot/sys/fs/selinux

    chroot /sysroot bash -c '
        /usr/sbin/load_policy -i
        for i in var home cfg usr/local; do
            [[ -e /$i/.autorelabel ]] || continue
            rm -f /$i/.autorelabel
            /usr/sbin/setfiles -m -F -v \
                /etc/selinux/targeted/contexts/files/file_contexts \
                /$i
        done
    ' 2>&1 | vwarn

    umount /sysroot/sys/fs/selinux
    umount /sysroot/sys
fi

: