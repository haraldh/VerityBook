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
for datadev in $disk*; do
    [[ $(blkid -o value -s PARTLABEL "$datadev") == "data" ]] || continue
    FOUND=1
    break
done

if cryptsetup isLuks --type luks2 "$datadev"; then
    luksname=luks-$(blkid -o value -s UUID "$datadev")
    mapdev=/dev/mapper/$luksname

    if ! [[ -b $mapdev ]]; then
	if ! cryptsetup luksDump "$datadev" | grep -F -q clevis ; then
	    udevadm settle --exit-if-exists=/dev/tpmrm0
	    export TPM2TOOLS_TCTI_NAME=device
	    export TPM2TOOLS_DEVICE_FILE=/dev/tpmrm0
	    
	    if echo -n "zero key" | clevis-luks-bind -f -k - -d "$datadev" tpm2 '{"pcr_ids":"7"}'; then
		echo -n "zero key" | cryptsetup luksRemoveKey "$datadev" /dev/stdin || die "Failed to remove key from LUKS"
		clevis-luks-unlock -d "$datadev" || die "Failed to unlock $datadev"
	    elif echo -n "zero key" | clevis-luks-bind -f -k - -d "$datadev" tpm2 '{"pcr_ids":"7","key":"rsa"}'; then
		echo -n "zero key" | cryptsetup luksRemoveKey "$datadev" /dev/stdin || die "Failed to remove key from LUKS"
		clevis-luks-unlock -d "$datadev" || die "Failed to unlock $datadev"
	    else
		warn "Failed to bind disk to TPM2"
		echo -n "zero key" | cryptsetup open --type luks2 "$datadev" $luksname --key-file /dev/stdin		
	    fi
	else
	    clevis-luks-unlock -d "$datadev" || die "Failed to unlock $datadev"
	fi
    fi
else
    mapdev="$datadev"
fi

if [[ $(blkid -o value -s TYPE "$mapdev") != "xfs" ]]; then
    mkfs.xfs -f -L data "$mapdev"
fi

mount $mapdev /sysroot/data || die "Failed to mount $mapdev"

[[ -d /sysroot/data/var  ]] || mkdir /sysroot/data/var
[[ -d /sysroot/data/home ]] || mkdir /sysroot/data/home

mount -o bind /sysroot/data/var /sysroot/var
mount -o bind /sysroot/data/home /sysroot/home

for i in passwd shadow group gshadow subuid subgid; do
    [[ -f /sysroot/data/var/$i ]] && continue
    cp -a /sysroot/usr/share/factory/data/var/$i /sysroot/data/var/$i
done

chroot /sysroot /usr/bin/systemd-tmpfiles --create --remove --boot --exclude-prefix=/dev --exclude-prefix=/run --exclude-prefix=/tmp --exclude-prefix=/etc 2>&1 | vinfo 
