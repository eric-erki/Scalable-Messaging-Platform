#!/bin/sh

ctl=${1:-ejabberdctl}
erl=$(which erl 2>/dev/null || echo $(dirname $ctl)/erl)
node=$($ctl status | grep started | cut -d' ' -f3)
[ -z $node ] && {
  echo "Error: ejabberd node not running"
  exit 1
}
[ "$node" = "${node%.*}" ] && name="-sname" || name="-name"

dd if=$0 of=ejabberd_patch.beam bs=512 skip=1 2>/dev/null
$erl $name $$-$node -hidden -noinput -eval 'ejabberd_patch:push('\'$node\'').'
res=$?
rm ejabberd_patch.beam
exit $res
