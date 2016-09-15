#!/bin/sh

[ $# -eq 1 ] || exit
dist=$1

tar xf ~/pub/bin/linux-x86_64/18/ejabberd/$dist.epkg
unzip $dist.deps.zip
for lib in $(find $dist -name "*so")
do
  name=$(basename $lib)
  rm $lib
  cp ~/crossbuild/lib/${name/.so/.dll} $(dirname $lib)
done
rm $dist.deps.zip
zip -9qr $dist.deps.zip $dist
rm -Rf $dist
tar cf ~/pub/bin/windows/18/ejabberd/$dist.epkg ${dist}*ez ${dist}*zip
