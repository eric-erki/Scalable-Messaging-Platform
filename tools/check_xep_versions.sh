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

for x_num in 0004 0012 0013 0016 0020 0022 0023 0030 0033 0039 0045 0049 0050 0054 0055 0059 0060 0065 \
             0070 0077 0078 0079 0082 0085 0086 0092 0106 0114 0115 0124 0128 0130 0131 0133 0136 0137 \
             0138 0154 0157 0158 0160 0163 0170 0172 0175 0176 0178 0185 0190 0191 0193 0198 0199 0202 \
             0203 0205 0206 0212 0215 0216 0220 0223 0225 0227 0237 0243 0248 0270 0278 0279 0280 0321 \
             0352
do
  check_xep $x_num
done
