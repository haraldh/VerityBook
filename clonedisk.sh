#!/bin/bash -ex

usage() {
    cat << EOF
Usage: $PROGNAME [OPTION]

  -h, --help             Display this help
  --crypt                Use Luks2 to encrypt the data partition (default PW: 1)
  --crypttpm2            as --crypt, but additionally auto-open with the use of a TPM2
  --simple               do not use dual-boot layout (e.g. for USB install media)
  --update               do not clear the data partition
EOF
}

TEMP=$(
    getopt -o '' \
        --long crypt \
        --long crypttpm2 \
	--long simple \
	--long update \
	--long help \
        -- "$@"
    )

if (( $? != 0 )); then
    usage >&2
    exit 1
fi

eval set -- "$TEMP"
unset TEMP

while true; do
    case "$1" in
        '--crypt')
	    USE_CRYPT="y"
            shift 1; continue
            ;;
        '--crypttpm2')
	    USE_CRYPT="y"
	    USE_TPM="y"
            shift 1; continue
            ;;
        '--simple')
	    SIMPLE="y"
            shift 1; continue
            ;;
        '--update')
	    UPDATE="y"
            shift 1; continue
            ;;
        '--help')
	    usage
	    exit 0
            ;;
        '--')
            shift
            break
            ;;
        *)
            echo 'Internal error!' >&2
            exit 1
            ;;
    esac
done

[[ $TMPDIR ]] || TMPDIR=/var/tmp
readonly TMPDIR="$(realpath -e "$TMPDIR")"
[ -d "$TMPDIR" ] || {
    printf "%s\n" "${PROGNAME}: Invalid tmpdir '$tmpdir'." >&2
    exit 1
}

readonly MY_TMPDIR="$(mktemp -p "$TMPDIR/" -d -t ${PROGNAME}.XXXXXX)"
[ -d "$MY_TMPDIR" ] || {
    printf "%s\n" "${PROGNAME}: mktemp -p '$TMPDIR/' -d -t ${PROGNAME}.XXXXXX failed." >&2
    exit 1
}

# clean up after ourselves no matter how we die.
trap '
    ret=$?;
    [[ $MY_TMPDIR ]] && mountpoint "$MY_TMPDIR"/data && umount "$MY_TMPDIR"/data
    [[ $MY_TMPDIR ]] && rm -rf --one-file-system -- "$MY_TMPDIR"
    exit $ret;
    ' EXIT

# clean up after ourselves no matter how we die.
trap 'exit 1;' SIGINT

mem=$(cat /proc/meminfo | { read a b a; echo $b; } )
mem=$(((mem-1)/1024/1024 + 1))
mem=${3:-$mem}

IN=$(readlink -e "$1")
OUT=$(readlink -e "$2")

[[ -b ${IN} ]]
[[ -b ${OUT} ]]

for i in ${OUT}*; do
    umount "$i" || :
done

if [[ ${IN#/dev/loop} != $IN ]]; then
    IN="${IN}p"
fi

if ! [[ $UPDATE ]]; then
    swapoff -a || :

    udevadm settle
    wipefs --all "$OUT"

    udevadm settle
    sfdisk -W always -w always "$OUT" << EOF
label: gpt
	    size=512MiB,  type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b, name="ESP System Partition"
            size=4GiB,    type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name="root1",  uuid=$(blkid -o value -s PARTUUID ${IN}3)
            size=4GiB,    type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name="root2"
            size=${mem}GiB,  type=0657fd6d-a4ab-43c4-84e5-0933c84b4f4e, name="swap"
            type=3b8f8425-20e0-4f3b-907f-1a25a76f98e9, name="data"
EOF
    udevadm settle
fi

OUT_DEV=$OUT

if [[ ${OUT#/dev/loop} != $OUT ]]; then
    OUT="${OUT}p"
fi
if [[ ${OUT#/dev/nvme} != $OUT ]]; then
    OUT="${OUT}p"
fi

dd if=${IN}2 of=${OUT}2 status=progress
sfdisk --part-uuid ${OUT_DEV} 2 $(blkid -o value -s PARTUUID ${IN}2)

if ! [[ $UPDATE ]]; then
    mkfs.fat -nEFI -F32 ${OUT}1

    if [[ $USE_CRYPT ]]; then
           # ------------------------------------------------------------------------------
        # swap
        echo -n "zero key" \
            | cryptsetup luksFormat --type luks2 ${OUT}4 /dev/stdin

        # ------------------------------------------------------------------------------
        # data
        echo -n "zero key" \
            | cryptsetup luksFormat --type luks2 ${OUT}5 /dev/stdin
    else
        mkswap ${OUT}4
        mkfs.xfs -L data ${OUT}5
    fi
fi

mkdir -p boot
mount ${OUT}1 boot
mkdir -p boot/EFI/FedoraBook
cp /efi/EFI/Boot/bootx64.efi boot/EFI/FedoraBook/1.efi
[[ -e /efi/Lockdown.efi ]] && cp /efi/Lockdown.efi boot
[[ -e /efi/Shell.efi ]] && cp /efi/Lockdown.efi boot/EFI/Boot/bootx64.efi

umount boot
rmdir boot

if ! [[ $UPDATE ]]; then
    for i in FED1 FED2 FED3 FED4; do
        efibootmgr -B -b $i || :
    done
    efibootmgr -C -b FED1 -d ${OUT_DEV} -p 1 -L "FedoraBook 1" -l '\efi\fedorabook\1.efi'
    efibootmgr -C -b FED2 -d ${OUT_DEV} -p 1 -L "FedoraBook 2" -l '\efi\fedorabook\2.efi'
    efibootmgr -C -b FED3 -d ${OUT_DEV} -p 1 -L "FedoraBook Old 1" -l '\efi\fedorabook\_1.efi'
    efibootmgr -C -b FED4 -d ${OUT_DEV} -p 1 -L "FedoraBook Old 2" -l '\efi\fedorabook\_2.efi'
    BOOT_ORDER=$(efibootmgr | grep BootOrder: | { read _ a; echo "$a"; })
    if ! [[ $BOOT_ORDER == *FED1* ]]; then
        efibootmgr -o "FED1,FED2,FED3,FED4,$BOOT_ORDER"
    fi
fi
