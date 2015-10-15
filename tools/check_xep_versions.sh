#!/bin/sh

check_xep()
{
    xep=xep-$1
    int=$(echo $1 | sed 's/^0*//')
    [ -f doc/$xep ] || curl -s -o doc/$xep http://xmpp.org/extensions/$xep.html
    title=$(sed '/<title>/!d;s/.*<title>\(.*\)<\/title>.*/\1/' doc/$xep)
    vsn=$(sed '/<strong>Version:/!d;s/.*<strong>Version:<\/strong><\/td><td>\([0-9.]*\)<\/td>.*/\1/' doc/$xep)
    imp=$(grep "{xep, $int," src/* | sed "s/src\/\(.*\).erl.*'\([0-9.-]*\)'.*/\1 \2/")
    [ "$imp" == "" ] && imp="NA 0.0"
    echo "$title;$vsn;${imp/ /;}"
}

[ -d doc ] || mkdir doc

for x_num in $(grep "{xep" src/* | sed "s/,//" | awk '{printf("%04d\n", $2)}' | sort -u)
do
  check_xep $x_num
done
