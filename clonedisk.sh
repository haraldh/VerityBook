#!/bin/bash

set -ex

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

wipefs --all "$OUT"

sfdisk -W always -w always "$OUT" << EOF
label: gpt
	    size=512MiB,  type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b, name="ESP System Partition"
            size=256M,    type=2c7357ed-ebd2-46d9-aec1-23d437ec2bf5, name="ver1",   uuid=$(blkid -o value -s PARTUUID ${IN}2)
            size=4GiB,    type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name="root1",  uuid=$(blkid -o value -s PARTUUID ${IN}3)
            size=256M,    type=2c7357ed-ebd2-46d9-aec1-23d437ec2bf5, name="ver2"
            size=4GiB,    type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name="root2"
            size=${mem}GiB,  type=0657fd6d-a4ab-43c4-84e5-0933c84b4f4f, name="swap"
            type=3b8f8425-20e0-4f3b-907f-1a25a76f98e9, name="data"
EOF

if [[ ${OUT#/dev/loop} != $OUT ]]; then
    OUT="${OUT}p"
fi
if [[ ${OUT#/dev/nvme} != $OUT ]]; then
    OUT="${OUT}p"
fi

for i in 1 2 3; do 
    dd if=${IN}${i} of=${OUT}${i} status=progress
done

# ------------------------------------------------------------------------------
# swap
mkswap -L swap ${OUT}6

# ------------------------------------------------------------------------------
# data
echo -n "zero key" \
    | cryptsetup luksFormat --type luks2 ${OUT}7 /dev/stdin
