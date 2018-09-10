#!/bin/bash -ex

JSON="$(realpath -e $1)"
BASEDIR="${JSON%/*}"

IMAGE="${BASEDIR}/$(jq -r '.name' ${JSON})-$(jq -r '.version' ${JSON})"

(
    cd "$IMAGE"
    [[ -f sha512sum.txt ]] || sha512sum * > sha512sum.txt
    [[ -f sha512sum.txt.sig ]] || gpg2 --detach-sign sha512sum.txt
)

if ! [[ -e "$IMAGE".tgz ]]; then
    tar cf - -C "${IMAGE%/*}" "${IMAGE##*/}" | pigz -c > "$IMAGE".tgz
fi
