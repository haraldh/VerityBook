#!/bin/bash -ex

CURDIR=$(pwd)
PROGNAME=${0##*/}

usage() {
    cat << EOF
Usage: $PROGNAME [OPTION]

  -h, --help             Display this help
  --force                Update, even if the signature checks fail
  --json JSON            Update from JSON, instead of downloading
EOF
}

TEMP=$(
    getopt -o '' \
        --long json: \
        --long force \
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
        '--json')
	        USE_JSON="$(readlink -e $2)"
            shift 2; continue
            ;;
        '--force')
	        FORCE="y"
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

BASEURL="$1"

. /etc/os-release

CURRENT_ROOT_HASH=$(</proc/cmdline)
CURRENT_ROOT_HASH=${CURRENT_ROOT_HASH#*roothash=}
CURRENT_ROOT_HASH=${CURRENT_ROOT_HASH%% *}

CURRENT_IMAGE_SIZE=$(</proc/cmdline)
CURRENT_IMAGE_SIZE=${CURRENT_IMAGE_SIZE#*verity.imagesize=}
CURRENT_IMAGE_SIZE=${CURRENT_IMAGE_SIZE%% *}

CURRENT_ROOT_UUID=${CURRENT_ROOT_HASH:32:8}-${CURRENT_ROOT_HASH:40:4}-${CURRENT_ROOT_HASH:44:4}-${CURRENT_ROOT_HASH:48:4}-${CURRENT_ROOT_HASH:52:12}

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

ROOT_DEV=$(get_disk $(bootdisk))

if ! [[ $ROOT_DEV ]]; then
    echo "Current partitions booted from not found!"
    exit 1
fi

unset FOUND
for dev in ${ROOT_DEV}-part*; do
    [[ $(blkid -o value -s PARTLABEL $dev) == root1 ]] &&
        ROOT1_DEV=$dev

    [[ $(blkid -o value -s PARTLABEL $dev) == root2 ]] &&
        ROOT2_DEV=$dev

    [[ $(blkid -o value -s PARTUUID $dev) == $CURRENT_ROOT_UUID ]] &&
        CURRENT_ROOT_DEV=$dev

    [[ $ROOT1_DEV ]] && [[ $ROOT2_DEV ]] && [[ $CURRENT_ROOT_DEV ]] && break
done

if ! [[ $ROOT1_DEV ]] || ! [[ $ROOT2_DEV ]] || ! [[ $CURRENT_ROOT_DEV ]]; then
    echo "Couldn't find partition numbers"
    exit 1
fi

[[ $CURRENT_ROOT_DEV == $ROOT2_DEV ]] \
    && NEW_ROOT_NUM=1 && OLD_ROOT_NUM=2 \
    && NEW_ROOT_PARTNO=${ROOT1_DEV##*-part}


[[ $CURRENT_ROOT_DEV == $ROOT1_DEV ]] \
    && NEW_ROOT_NUM=2 && OLD_ROOT_NUM=1 \
    && NEW_ROOT_PARTNO=${ROOT2_DEV##*-part}

ROOT_PARTNO=${CURRENT_ROOT_DEV##*-part}

if ! [[ $NEW_ROOT_PARTNO ]] || ! [[ $ROOT_PARTNO ]] || ! [[ $ROOT_DEV ]]; then
    echo "Couldn't find partition numbers"
    exit 1
fi

[[ ${NAME} ]]

mkdir -p /var/cache/${NAME}

readonly MY_TMPDIR="$(mktemp -p "/var/cache/${NAME}/" -d)"
[ -d "$MY_TMPDIR" ] || {
    printf "%s\n" "${PROGNAME}: mktemp -p '/var/cache/${NAME}/' -d failed." >&2
    exit 1
}

# clean up after ourselves no matter how we die.
trap '
    ret=$?;
    [[ $MY_TMPDIR ]] && rm -rf --one-file-system -- "$MY_TMPDIR"
    exit $ret;
    ' EXIT

# clean up after ourselves no matter how we die.
trap 'exit 1;' SIGINT

download_latest_json() {
    JSON="${NAME}-latest.json"
    rm -f "/var/cache/${NAME}/${JSON}"
    curl "${BASEURL}/${JSON}" --output /var/cache/${NAME}/${JSON}
    ROOT_HASH="$(jq -r '.roothash' /var/cache/${NAME}/${JSON})"
    VERSION="$(jq -r '.version' /var/cache/${NAME}/${JSON})"
    mv "/var/cache/${NAME}/${JSON}" "/var/cache/${NAME}/${NAME}-${VERSION}.json"
    JSON="/var/cache/${NAME}/${NAME}-${VERSION}.json"

    curl "${BASEURL}/${NAME}-${VERSION}.json.sig" \
        --output /var/cache/${NAME}/${NAME}-${VERSION}.json.sig

    if ! openssl dgst -sha256 -verify /etc/pki/${NAME}/pubkey \
        -signature /var/cache/${NAME}/${NAME}-${VERSION}.json.sig \
        "/var/cache/${NAME}/${NAME}-${VERSION}.json"
    then
        rm -f "/var/cache/${NAME}/${NAME}-${VERSION}.json" \
            "/var/cache/${NAME}/${NAME}-${VERSION}.json.sig"
        return 1
    fi
    return 0
}


if [[ $USE_JSON ]]; then
    JSON="${USE_JSON}"
else
    download_latest_json
fi

cd $MY_TMPDIR

JSONDIR="${JSON%/*}"
ROOT_HASH="$(jq -r '.roothash' ${JSON})"
IMAGE_SIZE="$(jq -r '.imagesize' ${JSON})"

if ! [[ $FORCE ]] && ( \
        [[ $CURRENT_ROOT_HASH == $ROOT_HASH ]] \
        || [[ -f /efi/EFI/${NAME}/bootx64-XXX-$ROOT_HASH.efi ]]
        )
then
    echo "Already up2date"
    exit 0
fi

check_delta_size() {
    local HASH="$1"
    local TARGET_HASH="$2"
    local SIZE NEW_HASH JSON NEW_SIZE
    curl -s "${BASEURL}/${NAME}-${HASH}-delta.json" \
        --output /var/cache/${NAME}/${NAME}-${HASH}-delta.json \
        || return -1
    curl -s "${BASEURL}/${NAME}-${HASH}-delta.json.sig" \
        --output /var/cache/${NAME}/${NAME}-${HASH}-delta.json.sig \
        || return -1
    openssl dgst -sha256 -verify /etc/pki/${NAME}/pubkey \
        -signature /var/cache/${NAME}/${NAME}-${HASH}-delta.json.sig \
        /var/cache/${NAME}/${NAME}-${HASH}-delta.json \
        &>/dev/null || return -1
    JSON="/var/cache/${NAME}/${NAME}-${HASH}-delta.json"
    SIZE="$(jq -r '.deltasize' $JSON)"
    NEW_HASH="$(jq -r '.roothash' ${JSON})"
    if [[ $NEW_HASH != $TARGET_HASH ]]; then
        NEW_SIZE=$(check_delta_size "$NEW_HASH" "$TARGET_HASH")
        [[ $? == -1 ]] && return -1
        SIZE=$(($SIZE + $NEW_SIZE))
    fi
    echo $SIZE
    return 0
}

download_delta_images() {
    local HASH="$1"
    local TARGET_HASH="$2"
    local SIZE NEW_HASH NEW_SIZE
    local JSON="/var/cache/${NAME}/${NAME}-${HASH}-delta.json"
    curl -s "${BASEURL}/${NAME}-${HASH}-delta.img" \
        --output /var/cache/${NAME}/${NAME}-${HASH}-delta.img \
        || return -1

    jq -r '.deltasig' ${JSON} | xxd -r -p > "$MY_TMPDIR/deltasig"

    openssl dgst -sha256 -verify /etc/pki/${NAME}/pubkey \
        -signature "$MY_TMPDIR/deltasig" \
        /var/cache/${NAME}/${NAME}-${HASH}-delta.img \
        &>/dev/null || return -1

    NEW_HASH="$(jq -r '.roothash' ${JSON})"
    if [[ $NEW_HASH != $TARGET_HASH ]]; then
        xdelta3 -c -d -s /dev/stdin /var/cache/${NAME}/${NAME}-${HASH}-delta.img \
            | download_delta_images "$NEW_HASH" "$TARGET_HASH"
    else
        xdelta3 -c -d -s /dev/stdin /var/cache/${NAME}/${NAME}-${HASH}-delta.img
    fi
}

if SIZE=$(check_delta_size "$CURRENT_ROOT_HASH" "$ROOT_HASH") && (($SIZE < $IMAGE_SIZE))
then
    dd if=$CURRENT_ROOT_DEV bs=4096 count=$(($CURRENT_IMAGE_SIZE/4096)) \
    | download_delta_images "$CURRENT_ROOT_HASH" "$ROOT_HASH" \
    | dd bs=4096 conv=fsync status=progress \
        of=${ROOT_DEV}-part${NEW_ROOT_PARTNO}
else
    curl -C - "${BASEURL}/${NAME}-${ROOT_HASH}.img" \
    | dd bs=4096 conv=fsync status=progress \
        of=${ROOT_DEV}-part${NEW_ROOT_PARTNO}
fi

jq -r '.rootimgsig' ${JSON} | xxd -r -p > "$MY_TMPDIR/rootimgsig"

if ! dd bs=4096 \
        if=${ROOT_DEV}-part${NEW_ROOT_PARTNO} \
        count=$(($IMAGE_SIZE/4096)) \
        | openssl dgst -sha256 -verify /etc/pki/${NAME}/pubkey \
            -signature "$MY_TMPDIR/rootimgsig" /dev/stdin;
then
    exit 1
fi

# set the new partition uuids
ROOT_UUID=${ROOT_HASH:32:8}-${ROOT_HASH:40:4}-${ROOT_HASH:44:4}-${ROOT_HASH:48:4}-${ROOT_HASH:52:12}

sfdisk --part-uuid ${ROOT_DEV} ${NEW_ROOT_PARTNO} ${ROOT_UUID}

jq -r '.efitarsig' ${JSON} | xxd -r -p > "$MY_TMPDIR/efitarsig"

curl -C - "${BASEURL}/${NAME}-${ROOT_HASH}-efi.tgz" \
    --output "/var/cache/${NAME}/${NAME}-${ROOT_HASH}-efi.tgz"

if ! openssl dgst -sha256 -verify /etc/pki/${NAME}/pubkey \
    -signature "$MY_TMPDIR/efitarsig" "${JSONDIR}/${NAME}-${ROOT_HASH}-efi.tgz";
    then
    rm -f "${JSONDIR}/${NAME}-${ROOT_HASH}-efi.tgz"
    exit 1
fi

tar xzf "${JSONDIR}/${NAME}-${ROOT_HASH}-efi.tgz"
# install to /efi
if [[ -d efi/EFI ]]; then
    cp -vr efi/EFI/* /efi/EFI/
fi

if [[ ! -f /efi/EFI/Boot/bootx64.efi ]] \
    || cmp --quiet /efi/EFI/${NAME}/${OLD_ROOT_NUM}.efi /efi/EFI/Boot/bootx64.efi \
    || cmp --quiet /efi/EFI/${NAME}/_${OLD_ROOT_NUM}.efi /efi/EFI/Boot/bootx64.efi
then
    cp /efi/EFI/${NAME}/bootx64-$ROOT_HASH.efi /efi/EFI/Boot/bootx64.efi
fi

cp /efi/EFI/${NAME}/bootx64-$ROOT_HASH.efi /efi/EFI/${NAME}/${NEW_ROOT_NUM}.efi

if [[ -f /efi/EFI/${NAME}/${OLD_ROOT_NUM}.efi ]]; then
    mv /efi/EFI/${NAME}/${OLD_ROOT_NUM}.efi /efi/EFI/${NAME}/_${OLD_ROOT_NUM}.efi
fi

rm -f /efi/EFI/${NAME}/_${NEW_ROOT_NUM}.efi

BOOT_ORDER=$(efibootmgr | grep BootOrder: | { read _ a; echo "$a"; })
BOOT_ORDER=${BOOT_ORDER//FED?,}
BOOT_ORDER=${BOOT_ORDER//FED?}
BOOT_ORDER=${BOOT_ORDER%,}
BOOT_ORDER=${BOOT_ORDER#,}

efibootmgr -o "FED${NEW_ROOT_NUM},FED$((${OLD_ROOT_NUM}+2)),$BOOT_ORDER"

for i in /efi/EFI/${NAME}/bootx64-*.efi; do
    [[ $i == /efi/EFI/${NAME}/bootx64-$ROOT_HASH.efi ]] && continue
    [[ $i == /efi/EFI/${NAME}/bootx64-$CURRENT_ROOT_HASH.efi ]] && continue
    rm -f "$i"
done

echo "Update successful. Reboot your machine to use it."
