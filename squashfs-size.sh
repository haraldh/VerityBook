#!/bin/bash

getbyte () {
    local IFS= LC_CTYPE=C res c
    read -r -n 1 -d '' c
    res=$?
    # the single quote in the argument of the printf
    # yields the numeric value of $c (ASCII since LC_CTYPE=C)
    [[ -n $c ]] && c=$(printf '%u' "'$c") || c=0
    printf "$c"
    return $res
}

getword () {
    local b1 b2 val
    b1=$(getbyte) || return 1
    b2=$(getbyte) || return 1
    (( val = b2 * 256 + b1 ))
    echo $val
    return 0
}

getuint () {
    local b1 b2 val
    b1=$(getword) || return 1
    b2=$(getword) || return 1
    (( val = b2 * 256 * 256 + b1 ))
    echo $val
    return 0
}

squashfs_size() {
    size=$(for i in {1..20}; do getword >/dev/null; done; getuint)
    echo $(((size+4095)/4096*4096))
}

squashfs_size

