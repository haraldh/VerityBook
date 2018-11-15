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
BASEOUTDIR="${JSON%/*}"
NAME="$(jq -r '.name' ${JSON})"
VERSION="$(jq -r '.version' ${JSON})"
ROOTHASH="$(jq -r '.roothash' ${JSON})"
IMAGE="${BASEOUTDIR}/${NAME}-${VERSION}"
HASH_IMAGE="${BASEOUTDIR}/${NAME}-${ROOTHASH}"
CRT=${CRT:-${BASEDIR}/${NAME}.crt}
KEY=${KEY:-${BASEDIR}/${NAME}.key}

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
    [[ $MY_TMPDIR ]] && rm -rf --one-file-system -- "$MY_TMPDIR"
    exit $ret;
    ' EXIT

# clean up after ourselves no matter how we die.
trap 'exit 1;' SIGINT

cd "$MY_TMPDIR"

if ! [[ $KEY ]] || ! [[ $CRT ]]; then
    echo "Cannot find $KEY and $CRT"
    echo "Need --key KEY --crt CRT options"
    exit 1
fi

tar xzf "${HASH_IMAGE}-efi.tgz"
for i in $(find efi -type f -name '*.efi'); do
    [[ -f "$i" ]] || continue
    if ! sbverify --cert "$CRT" "$i" &>/dev/null ; then
        sbsign --key "$KEY" --cert "$CRT" --output "${i}signed" "$i"
        mv "${i}signed" "$i"
    fi
done

rm "${HASH_IMAGE}-efi.tgz"
tar cf - efi | pigz -c > "${HASH_IMAGE}-efi.tgz"

openssl dgst -sha256 -sign "$KEY" \
    -out efi.sig "${HASH_IMAGE}-efi.tgz"

openssl dgst -sha256 -sign "$KEY" \
    -out img.sig "${HASH_IMAGE}.img"

jq "( . + {\"efitarsig\": \"$(xxd -c256 -p -g0 \
    < efi.sig)\"} + {\"rootimgsig\":\"$(xxd -c256 -p -g0 \
    < img.sig)\"})" \
    > "${IMAGE}.json.new" < "${IMAGE}.json" \
    && mv --force "${IMAGE}.json.new" "${IMAGE}.json"

openssl dgst -sha256 -sign "$KEY" \
    -out "${IMAGE}.json.sig" "${IMAGE}.json"
