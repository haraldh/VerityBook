#!/bin/bash -ex

usage() {
    cat << EOF
Usage: $PROGNAME [OPTION] LATEST.JSON

  -h, --help             Display this help
  --nosign               Don't sign the EFI executable
  --key KEY            Use KEY as certification key for EFI signing
  --crt CRT            Use CRT as certification for EFI signing
EOF
}

TEMP=$(
    getopt -o '' \
        --long key: \
        --long crt: \
        --long nosign \
        --long notar \
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
        '--nosign')
            NOSIGN="1"
            shift 1; continue
            ;;
        '--notar')
            NOTAR="1"
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
HASH_IMAGE="${JSONDIR}/${NAME}-${ROOTHASH}"
CRT=${CRT:-${BASEDIR}/${NAME}.crt}
KEY=${KEY:-${BASEDIR}/${NAME}.key}

pushd "$IMAGE"
if ! [[ $NOSIGN ]]; then
    if ! [[ $KEY ]] || ! [[ $CRT ]]; then
        echo "Cannot find $KEY and $CRT"
        echo "Need --key KEY --crt CRT options"
        exit 1
    fi
    for i in $(find . -type f -name '*.efi'); do
        [[ -f "$i" ]] || continue
        if ! sbverify --cert "$CRT" "$i" &>/dev/null ; then
            sbsign --key "$KEY" --cert "$CRT" --output "${i}signed" "$i"
            mv "${i}signed" "$i"
        fi
    done
fi

[[ -f sha512sum.txt ]] || sha512sum $(find . -type f) > sha512sum.txt
[[ -f sha512sum.txt.sig ]] || openssl dgst -sha256 -sign "$KEY" -out sha512sum.txt.sig sha512sum.txt

if ! [[ $NOTAR ]]; then
    [[ -e "$IMAGE".tgz ]] || tar cf - -C "${IMAGE%/*}" "${IMAGE##*/}" | pigz -c > "${IMAGE}.tgz"
    if ! [[ -e "$HASH_IMAGE-efi".tgz ]]; then
        tar cf - efi | pigz -c > "$HASH_IMAGE-efi.tgz"
    fi
    [[ $NOSIGN ]] || openssl dgst -sha256 -sign "$KEY" \
        -out "${HASH_IMAGE}-efi.tgz.sig" "${HASH_IMAGE}-efi.tgz"
    [[ $NOSIGN ]] || openssl dgst -sha256 -sign "$KEY" \
        -out "${JSONDIR}/${NAME}-${ROOTHASH}.img.sig" "$IMAGE/root.img"
fi

popd
