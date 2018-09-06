#!/bin/bash -ex

BASEURL="$1"

. /etc/os-release

CURRENT_ROOT_HASH=$(</proc/cmdline)
CURRENT_ROOT_HASH=${CURRENT_ROOT_HASH#*roothash=}
CURRENT_ROOT_HASH=${CURRENT_ROOT_HASH%% *}

CURRENT_ROOT_UUID=${CURRENT_ROOT_HASH:32:8}-${CURRENT_ROOT_HASH:40:4}-${CURRENT_ROOT_HASH:44:4}-${CURRENT_ROOT_HASH:48:4}-${CURRENT_ROOT_HASH:52:12}
CURRENT_HASH_UUID=${CURRENT_ROOT_HASH:0:8}-${CURRENT_ROOT_HASH:8:4}-${CURRENT_ROOT_HASH:12:4}-${CURRENT_ROOT_HASH:16:4}-${CURRENT_ROOT_HASH:20:12}

[[ /dev/disk/by-partlabel/root1 -ef /dev/disk/by-partuuid/${CURRENT_ROOT_UUID} ]] \
    && [[ /dev/disk/by-partlabel/ver1 -ef /dev/disk/by-partuuid/${CURRENT_HASH_UUID} ]] \
    && NEW_ROOT_NUM=2

[[ /dev/disk/by-partlabel/root2 -ef /dev/disk/by-partuuid/${CURRENT_ROOT_UUID} ]] \
    && [[ /dev/disk/by-partlabel/ver2 -ef /dev/disk/by-partuuid/${CURRENT_HASH_UUID} ]] \
    && NEW_ROOT_NUM=1

if ! [[ $NEW_ROOT_NUM ]]; then
    echo "Current partitions booted from not found!"
    exit 1
fi

## find base device and partition number
for dev in /dev/disk/by-path/*; do
    if ! [[ $VER_PARTNO ]] && [[ /dev/disk/by-partlabel/ver${NEW_ROOT_NUM} -ef $dev ]]; then
        VER_PARTNO=${dev##*-part}
        ROOT_DEV=${dev%-part*}
    fi
    if ! [[ $ROOT_PARTNO ]] && [[ /dev/disk/by-partlabel/root${NEW_ROOT_NUM} -ef $dev ]]; then
        ROOT_PARTNO=${dev##*-part}
        ROOT_DEV=${dev%-part*}
    fi
    [[ $ROOT_PARTNO ]] && [[ $VER_PARTNO ]] && break
done

if ! [[ $ROOT_PARTNO ]] || ! [[ $VER_PARTNO ]] || ! [[ $ROOT_DEV ]]; then
    echo "Couldn't find partition numbers"
    exit 1
fi

mkdir -p /var/cache/${NAME}
cd /var/cache/${NAME}

curl ${BASEURL}/${NAME}-latest.txt --output ${NAME}-latest.txt

RELEASE=$(read a b <${NAME}-latest.txt ; echo -n $b)
ROOT_HASH=$(read a b <${NAME}-latest.txt; echo -n $a)

ROOT_UUID=${ROOT_HASH:32:8}-${ROOT_HASH:40:4}-${ROOT_HASH:44:4}-${ROOT_HASH:48:4}-${ROOT_HASH:52:12}
HASH_UUID=${ROOT_HASH:0:8}-${ROOT_HASH:8:4}-${ROOT_HASH:12:4}-${ROOT_HASH:16:4}-${ROOT_HASH:20:12}
            
if [[ $CURRENT_ROOT_HASH == $ROOT_HASH ]] || [[ ${NAME}-${VERSION_ID} == $RELEASE ]]; then
    echo "Already up2date"
    exit 1
fi

curl ${BASEURL}/${RELEASE}.tgz | tar xzf -

[[ -d ${RELEASE} ]]

cd ${RELEASE}

dd status=progress if=root.verity.img   of=/dev/disk/by-partlabel/ver${NEW_ROOT_NUM}
dd status=progress if=root.squashfs.img of=/dev/disk/by-partlabel/root${NEW_ROOT_NUM}

# set the new partition uuids
sfdisk --part-uuid ${ROOT_DEV} ${VER_PARTNO} ${HASH_UUID}
sfdisk --part-uuid ${ROOT_DEV} ${ROOT_PARTNO} ${ROOT_UUID}

# install to /efi
mkdir -p /efi/EFI/${NAME}
cp bootx64.efi /efi/EFI/${NAME}/${NEW_ROOT_NUM}.efi

## unless proper boot entries set, just force copy to default boot loader
cp bootx64.efi /efi/EFI/Boot/new_bootx64.efi
mv --backup=numbered /efi/EFI/Boot/new_bootx64.efi /efi/EFI/Boot/bootx64.efi
