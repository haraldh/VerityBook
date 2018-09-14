#!/bin/bash -ex

CURDIR=$(pwd)
PROGNAME=${0##*/}

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
. /etc/os-release

while true; do
    case "$1" in
        '--crypt')
	    USE_CRYPT="y"
            shift 1; continue
            ;;
        '--crypttpm2')
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

SOURCE=$(readlink -e "$1")
IMAGE=$(readlink -f "$2")

if ! [[ -d $SOURCE ]]; then
    SOURCE="${SOURCE%/*}/$(jq -r '.name' "$SOURCE")-$(jq -r '.version' "$SOURCE")"
fi

if ! [[ -d $SOURCE ]] || ! [[ $IMAGE ]]; then
    usage
    exit 1
fi


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
    for i in "$MY_TMPDIR"/boot "$MY_TMPDIR"/data; do
       [[ -d "$i" ]] && mountpoint -q "$i" && umount "$i"
    done
    [[ $DEV ]] && losetup -d $DEV 2>/dev/null || :
    [[ $MY_TMPDIR ]] && rm -rf --one-file-system -- "$MY_TMPDIR"
    exit $ret;
    ' EXIT

# clean up after ourselves no matter how we die.
trap 'exit 1;' SIGINT

ROOT_HASH=$(<"$SOURCE"/root-hash.txt)

ROOT_UUID=${ROOT_HASH:32:8}-${ROOT_HASH:40:4}-${ROOT_HASH:44:4}-${ROOT_HASH:48:4}-${ROOT_HASH:52:12}

# ------------------------------------------------------------------------------
# Testdisk

# create GPT table with EFI System Partition
if ! [[ -b "${IMAGE}" ]]; then
    if ! [[ $UPDATE ]]; then
        rm -f "${IMAGE}"
        dd if=/dev/null of="${IMAGE}" bs=1MiB seek=$((15*1024)) count=1
    fi
    readonly DEV=$(losetup --show -f -P "${IMAGE}")
    readonly DEV_PART=${DEV}p
else
    for i in ${IMAGE}*; do
	umount "$i" || :
    done

    if ! [[ $UPDATE ]]; then
        wipefs --force --all "${IMAGE}"
    fi
    readonly DEV="${IMAGE}"
    readonly DEV_PART="${IMAGE}"
fi

udevadm settle
if ! [[ $UPDATE ]]; then
    sfdisk "${DEV}" << EOF
label: gpt
	    size=512MiB,  type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b, name="ESP System Partition"
            size=4GiB,    type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name="root1", uuid=$ROOT_UUID
                          type=3b8f8425-20e0-4f3b-907f-1a25a76f98e9, name="data"
EOF

    udevadm settle
    for i in 1 2 3; do
        wipefs --force --all ${DEV_PART}${i}
    done
    udevadm settle
else
    sfdisk --part-uuid ${DEV} 3 ${ROOT_UUID}
fi

# ------------------------------------------------------------------------------
# ESP
if ! [[ $UPDATE ]]; then
    mkfs.fat -nEFI -F32 ${DEV_PART}1
fi
mkdir "$MY_TMPDIR"/boot
mount ${DEV_PART}1 "$MY_TMPDIR"/boot

mkdir -p "$MY_TMPDIR"/boot/EFI/Boot
mkdir -p "$MY_TMPDIR"/boot/EFI/FedoraBook
if [[ -e "${SOURCE}"/Shell.efi ]] && [[ -e "${SOURCE}"/startup.nsh ]] && [[ -e "${SOURCE}"/LockDown.efi ]]; then
    cp "${SOURCE}"/startup.nsh "$MY_TMPDIR"/boot/
    cp "${SOURCE}"/LockDown.efi "$MY_TMPDIR"/boot/
    cp "${SOURCE}"/Shell.efi "$MY_TMPDIR"/boot/EFI/Boot/bootx64.efi
    cp "$SOURCE"/bootx64.efi "$MY_TMPDIR"/boot/EFI/FedoraBook/bootx64.efi
else
    cp "$SOURCE"/bootx64.efi "$MY_TMPDIR"/boot/EFI/Boot/bootx64.efi
fi
umount "$MY_TMPDIR"/boot

# ------------------------------------------------------------------------------
# root1
dd if="$SOURCE"/root.img of=${DEV_PART}2 status=progress

# ------------------------------------------------------------------------------
# data
if ! [[ $UPDATE ]]; then
    mkfs.xfs -L data ${DEV_PART}3
fi
# ------------------------------------------------------------------------------
# DONE

sync
losetup -d $DEV || :
eject "$DEV" || :
sync
