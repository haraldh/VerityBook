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
DISTDIR="${JSON%/*}"
NAME="$(jq -r '.name' ${JSON})"
VERSION="$(jq -r '.version' ${JSON})"
ROOTHASH="$(jq -r '.roothash' ${JSON})"
IMAGE="${DISTDIR}/${NAME}-${VERSION}.json"
CRT=${CRT:-${BASEDIR}/${NAME}.crt}
KEY=${KEY:-${BASEDIR}/${NAME}.key}

mkdelta_f() {
    local OLD="$1"
    local NEW="$2"
    local DELTANAME="$DISTDIR/$NAME-$(jq -r '.roothash' "$OLD")"
    local OLDIMAGE="$DISTDIR/$NAME-$(jq -r '.roothash' "$OLD").img"
    local NEWHASH=$(jq -r '.roothash' "$NEW")
    local NEWIMAGE="$DISTDIR/$NAME-$NEWHASH.img"
    xdelta3 -9 -f -S djw -s "$OLDIMAGE" "$NEWIMAGE" "$DELTANAME"-delta.new
    openssl dgst -sha256 -sign "$KEY" -out "$DELTANAME"-delta.new.sig "$DELTANAME"-delta.new

    mv "$DELTANAME"-delta.new "$DELTANAME"-delta.img
    DELTA_IMAGE_SIZE=$(stat --printf '%s' "$DELTANAME"-delta.img)
    jq "( . + {\
            \"deltasig\": \"$(xxd -c256 -p -g0 < "$DELTANAME"-delta.new.sig)\",\
            \"deltasize\": \"${DELTA_IMAGE_SIZE}\",\
        })" \
        < "${NEW}" > "${DELTANAME}-delta.json"
    rm -f "$DELTANAME"-delta.new.sig

    openssl dgst -sha256 -sign "$KEY" -out "${DELTANAME}-delta.json.sig" "${DELTANAME}-delta.json"
}

for i in $(ls -1 "${DISTDIR}/${NAME}-"*.??????????????.json); do
    [[ -f "$i" ]] || continue

    OLDIMAGE=$(realpath $i)
    if [[ $OLDIMAGE == $IMAGE ]]; then
        break
    fi

    mkdelta_f "$OLDIMAGE" "$IMAGE"
    if [[ $CHECKPOINT ]]; then
        OLDHASH="$(jq -r '.roothash' "$OLDIMAGE")"
        OLDNAME="$(jq -r '.name' "$OLDIMAGE")"
        rm -f \
            "$OLDIMAGE" \
            "$OLDIMAGE".sig \
            "${DISTDIR}/$OLDNAME"-"$OLDHASH".img \
            "${DISTDIR}/$OLDNAME"-"$OLDHASH"-efi.tgz "${DISTDIR}/$OLDNAME"-"$OLDHASH"-efi.tgz.sig \
            "${DISTDIR}/$OLDNAME"-"$OLDHASH".json "${DISTDIR}/$OLDNAME"-"$OLDHASH".json.sig
    fi
done
