#!/bin/bash -ex

usage() {
    cat << EOF
Usage: $PROGNAME [OPTION]

  -h, --help             Display this help
  --nosign               Don't sign the EFI executable
  --certdir DIR          Use DIR as certification CA for EFI signing
EOF
}

TEMP=$(
    getopt -o '' \
        --long certdir: \
        --long nosign \
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
        '--certdir')
	    CERTDIR="$(readlink -e $2)"
            shift 2; continue
            ;;
        '--nosign')
	    NOSIGN="1"
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

JSON="$(realpath -e $1)"
BASEDIR="${JSON%/*}"
IMAGE="${BASEDIR}/$(jq -r '.name' ${JSON})-$(jq -r '.version' ${JSON})"

(
    cd "$IMAGE"
    if ! [[ $NOSIGN ]]; then
        pesign -c DB -s ${CERTDIR:+--certdir $CERTDIR} -i bootx64.efi -o bootx64-signed.efi
        mv bootx64-signed.efi bootx64.efi
    fi
    [[ -f sha512sum.txt ]] || sha512sum * > sha512sum.txt
    [[ -f sha512sum.txt.sig ]] || gpg2 --detach-sign sha512sum.txt
)

if ! [[ -e "$IMAGE".tgz ]]; then
    tar cf - -C "${IMAGE%/*}" "${IMAGE##*/}" | pigz -c > "$IMAGE".tgz
fi
