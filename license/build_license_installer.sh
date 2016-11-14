#!/bin/sh

[ $# -eq 3 ] || exit 4

installer=$1
version=$2
license=$3

size=$(wc -c tools/ejabberd_patch.sh | cut -d' ' -f1)
offset=$((size%512))
cp tools/ejabberd_patch.sh $installer.run
dd if=/dev/zero bs=1 count=$((512-offset)) >> $installer.run 2>/dev/null
tools/build_license.es $version $license
erlc tools/ejabberd_patch.erl
dd if=ejabberd_patch.beam bs=512 >> $installer.run 2>/dev/null
rm ejabberd_patch.beam ejabberd_patch.hrl
