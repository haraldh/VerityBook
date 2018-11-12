#!/bin/bash -ex

usage() {
    cat << EOF
Usage: $PROGNAME [OPTION] LATEST.JSON

  -h, --help    Display this help
  --key KEY     Use KEY as certification key for EFI signing
  --crt CRT     Use CRT as certification for EFI signing
  --checkpoint  Remove old directories and tarballs
EOF
}

TEMP=$(
    getopt -o '' \
        --long key: \
        --long crt: \
        --long checkpoint \
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
        '--key')
            KEY="$(readlink -e $2)"
            shift 2; continue
            ;;
        '--crt')
            CRT="$(readlink -e $2)"
            shift 2; continue
            ;;
        '--checkpoint')
            CHECKPOINT="1"
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
PROGNAME=${0##*/}
BASEDIR=$(realpath ${0%/*})

JSON="$(realpath -e $1)"
JSONDIR="${JSON%/*}"
NAME="$(jq -r '.name' ${JSON})"
VERSION="$(jq -r '.version' ${JSON})"
ROOTHASH="$(jq -r '.roothash' ${JSON})"
IMAGE="${JSONDIR}/${NAME}-${VERSION}"
CRT=${CRT:-${BASEDIR}/${NAME}.crt}
KEY=${KEY:-${BASEDIR}/${NAME}.key}

mkdelta_f() {
    OLD="$1"
    NEW="$2"
    if [[ -e "$OLD"/root-hash.txt ]]; then
        DELTANAME="$JSONDIR/$NAME-$(<"$OLD"/root-hash.txt)"
    else
        DELTANAME="$JSONDIR/$NAME-"$(jq -r '.roothash' "$OLD"/release.json)""
    fi
    xdelta3 -9 -f -S djw -s "$OLD"/root.img "$NEW"/root.img "$DELTANAME"-delta.new
    openssl dgst -sha256 -sign "$KEY" -out "$DELTANAME"-delta.new.sig "$DELTANAME"-delta.new
    mv "$DELTANAME"-delta.new "$DELTANAME"-delta.img
    mv "$DELTANAME"-delta.new.sig "$DELTANAME"-delta.img.sig
    cp "${NEW}/release.json" "${DELTANAME}.json"
    openssl dgst -sha256 -sign "$KEY" -out "${DELTANAME}.json.sig" "${DELTANAME}.json"
}

for i in $(ls -1d "${JSONDIR}/${NAME}-"*); do
    [[ -d "$i" ]] || continue

    OLDIMAGE=$(realpath $i)
    if [[ $OLDIMAGE == $IMAGE ]]; then
        break
    fi

    mkdelta_f "$OLDIMAGE" "$IMAGE"
    [[ $CHECKPOINT ]] && rm -fr "$OLDIMAGE" "$OLDIMAGE".tgz "$OLDIMAGE"-efi.tgz "$OLDIMAGE"-efi.tgz.sig
done
