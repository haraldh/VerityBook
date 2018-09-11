#!/bin/bash

mkdir -p "$sysroot"/etc/udev/rules.d
cp "$CURDIR/69-yubikey.rules" "$sysroot"/etc/udev/rules.d
