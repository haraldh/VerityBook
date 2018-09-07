#!/bin/bash

root=$(getarg systemd.verity_root_hash)

case "$root" in
    block:LABEL=*|LABEL=*)
        root="${root#block:}"
        root="$(echo $root | sed 's,/,\\x2f,g')"
        root="/dev/disk/by-label/${root#LABEL=}"
        rootok=1 ;;
    block:UUID=*|UUID=*)
        root="${root#block:}"
        root="${root#UUID=}"
        root="$(echo $root | tr "[:upper:]" "[:lower:]")"
        root="/dev/disk/by-uuid/${root#UUID=}"
        rootok=1 ;;
    block:PARTUUID=*|PARTUUID=*)
        root="${root#block:}"
        root="${root#PARTUUID=}"
        root="$(echo $root | tr "[:upper:]" "[:lower:]")"
        root="/dev/disk/by-partuuid/${root}"
        rootok=1 ;;
    block:PARTLABEL=*|PARTLABEL=*)
        root="${root#block:}"
        root="/dev/disk/by-partlabel/${root#PARTLABEL=}"
        rootok=1 ;;
    /dev/*)
        rootok=1 ;;
esac

unset FOUND
for d in /dev/disk/by-path/*; do
    [[ $d -ef $root ]] || continue
    FOUND=1
    break
done

[[ $FOUND ]] || die "No boot disk found"

disk=${d%-part*}

unset FOUND
for swapdev in $disk*; do
    [[ $(blkid -o value -s PARTLABEL "$swapdev") == "swap" ]] || continue
    FOUND=1
    break
done

if [[ $FOUND ]]; then
    if cryptsetup isLuks --type luks2 "$swapdev"; then
        luksname=swap
        luksdev=/dev/mapper/$luksname

        if ! cryptsetup luksDump "$swapdev" | grep -F -q clevis ; then
            udevadm settle --exit-if-exists=/dev/tpmrm0
            export TPM2TOOLS_TCTI_NAME=device
            export TPM2TOOLS_DEVICE_FILE=/dev/tpmrm0

            if echo -n "zero key" | clevis-luks-bind -f -k - -d "$swapdev" tpm2 '{"pcr_ids":"7"}'; then
                clevis-luks-unlock -d "$swapdev" -n "$luksname" || die "Failed to unlock $swapdev"
                echo -n "zero key" | cryptsetup luksRemoveKey "$swapdev" /dev/stdin || die "Failed to remove key from LUKS"
            elif echo -n "zero key" | clevis-luks-bind -f -k - -d "$swapdev" tpm2 '{"pcr_ids":"7","key":"rsa"}'; then
                clevis-luks-unlock -d "$swapdev" -n "$luksname" || die "Failed to unlock $swapdev"
                echo -n "zero key" | cryptsetup luksRemoveKey "$swapdev" /dev/stdin || die "Failed to remove key from LUKS"
            else
                warn "Failed to bind swap disk to TPM2"
            fi
        else
            clevis-luks-unlock -d "$swapdev" -n "$luksname" || die "Failed to unlock $swapdev"
        fi
        swapdev="$luksdev"
    fi

    swaptype=$(blkid -o value -s TYPE "$swapdev")
    [[ $swaptype == "swsuspend" ]] && \
        /usr/lib/systemd/systemd-hibernate-resume "$swapdev"

    [[ $swaptype != "swap" ]] && \
        mkswap "$swapdev"

    swapon "$swapdev"
fi


unset FOUND
for datadev in $disk*; do
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
            udevadm settle --exit-if-exists=/dev/tpmrm0
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

mount -o discard $datadev /sysroot/data || die "Failed to mount $datadev"

[[ -d /sysroot/data/var  ]] || mkdir /sysroot/data/var
[[ -d /sysroot/data/home ]] || mkdir /sysroot/data/home

mount -o bind /sysroot/data/var /sysroot/var
mount -o bind /sysroot/data/home /sysroot/home

for i in passwd shadow group gshadow subuid subgid; do
    [[ -f /sysroot/data/var/$i ]] && continue
    cp -a /sysroot/usr/share/factory/data/var/$i /sysroot/data/var/$i
done

chroot /sysroot /usr/bin/systemd-tmpfiles --create --remove --boot --exclude-prefix=/dev --exclude-prefix=/run --exclude-prefix=/tmp --exclude-prefix=/etc 2>&1 | vinfo
