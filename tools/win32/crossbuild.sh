#!/bin/sh

# this script must be installed in cean@build.vpn.p1:crossbuild
# and be run under the right cean context
# usage:
#  ssh cean
#  cean20
#  cd ~/crossbuild
#  ./crossbuild.sh ejabberd-17.12
#  cdr
#  export/bitrock ejabberd windows

[ $# -eq 1 ] || {
  echo "error: no ejabberd version provided"
  echo
}
dist=$1
erts=9.2
otp=20
zlib=zlib-1.2.8
expat=expat-2.1.0
yaml=yaml-0.1.5
ssl=openssl-1.0.2l
iconv=libiconv-1.14
sql=sqlite-autoconf-3081002

master="~/pub/bin/linux-x86_64/$otp/ejabberd/$dist.epkg"
[ -f $dist.epkg ] && master="$PWD/$dist.epkg"

[ -f ~/pub/src/ejabberd/$dist.tgz ] || {
  echo "error: no source tarball"
  exit
}
[ -f "$master" ] || {
  echo "error: no ejabberd epkg available"
  exit
}

root=~/crossbuild
dll=$root/lib
cd $root
[ -e ejabberd ] && rm ejabberd
tar zxf ~/pub/src/ejabberd/$dist.tgz
ln -s $dist ejabberd

ejsrc=ejabberd
ejdeps=$root/$ejsrc/deps

CHOST=x86_64-w64-mingw32
CC=$CHOST-gcc
CCX=$CHOST-g++
LD=$CHOST-ld
AR=$CHOST-ar
AS=$CHOST-as
RC=$CHOST-windres
ST=$CHOST-strip
w=/usr/$CHOST/include
i=$root/erl$erts/usr/include
l=$root/erl$erts/usr/lib
h=$CEAN_ROOT/src/otp/erts/emulator/sys/win32
e=$CEAN_ROOT/src/otp/lib/erl_interface/include

mkdir -p $dll
(cd $ejsrc
 ./autogen.sh
 ./configure --enable-mysql --enable-pgsql --enable-sqlite --enable-riak --enable-redis --enable-elixir --enable-sip --enable-stun --disable-graphics
 ./rebar get-deps)

cd $ejdeps/ezlib/c_src
rm *o
$CC -I$w -I$h -I$i -I$e -I$root/$zlib -D_WIN32 -c ezlib_drv.c
$CC -shared -o $dll/ezlib_drv.dll ezlib_drv.o $l/ei_md.lib $dll/zlib1.dll
cd -

cd $ejdeps/stringprep
patch -p1<$root/stringprep.patch
cd c_src
rm *o
$CC -I$w -I$h -I$i -I$e -D_WIN32 -c *c
$CCX -I$w -I$h -I$i -I$e -D_WIN32 -c *cpp
$CCX -shared -static-libgcc -static-libstdc++ -o $dll/stringprep.dll *o
cd -

cd $ejdeps/fast_xml
patch -p1<$root/xml.patch
cd c_src
rm *o
[ -d $root/$expat ] || curl http://kent.dl.sourceforge.net/project/expat/expat/${expat#*-}/$expat.tar.gz | tar -C $root -zxf -
(cd $root/$expat; ./configure --host=$CHOST; make)
$CC -I$w -I$h -I$i -I$e -I$root/$expat/lib -D_WIN32 -c fxml.c fxml_stream.c
$CC -shared -o $dll/fxml.dll fxml.o
$CC -shared -o $dll/fxml_stream.dll fxml_stream.o $root/$expat/.libs/libexpat.a
cd -

cd $ejdeps/fast_yaml/c_src
rm *o
[ -d $root/$yaml ] || curl http://pyyaml.org/download/libyaml/$yaml.tar.gz | tar -C $root -zxf -
(cd $root/$yaml; ./configure CFLAGS="-DYAML_DECLARE_STATIC" --enable-static --disable-shared --host=$CHOST; make)
$CC -I$w -I$h -I$i -I$e -I$root/$yaml/include -DYAML_DECLARE_STATIC -D_WIN32 -c fast_yaml.c
$CC -shared -o $dll/fast_yaml.dll fast_yaml.o $root/$yaml/src/.libs/libyaml.a
cd -

cd $ejdeps/fast_tls
cd c_src
rm *o
[ -d $root/$ssl ] || curl https://www.openssl.org/source/$ssl.tar.gz | tar -C $root -zxf -
(cd $root/$ssl; ./Configure mingw64; make CC=$CC; $CHOST-ranlib *.a)
$CC -I$w -I$h -I$i -I$e -I$root/$ssl/include -D_WIN32 -c p1_sha.c fast_tls.c hashmap.c
$CC -shared -o $dll/p1_sha.dll p1_sha.o $root/$ssl/libcrypto.a
$CC -shared -o $dll/fast_tls.dll fast_tls.o hashmap.o $root/$ssl/libssl.a $root/$ssl/libcrypto.a /usr/$CHOST/lib/libgdi32.a /usr/$CHOST/lib/libwsock32.a
cd -

cd $ejdeps/iconv/c_src
rm *o
[ -d $root/$iconv ] || curl http://ftp.gnu.org/pub/gnu/libiconv/$iconv.tar.gz | tar -C $root -zxf -
(cd $root/$iconv; ./configure --host=$CHOST; make)
$CC -I$w -I$h -I$i -I$e -I$root/$iconv/include -D_WIN32 -c iconv.c
$CC -shared -o $dll/iconv.dll iconv.o $root/$iconv/lib/.libs/libiconv-2.dll
cd -

cd $ejdeps/sqlite3/c_src
rm *o
[ -d $root/$sql ] || curl https://sqlite.org/2015/$sql.tar.gz | tar -C $root -zxf -
(cd $root/$sql; CFLAGS="-D_WIN32" ./configure --host=$CHOST; make; cp sqlite3.exe $dll)
$CC -I$w -I$h -I$i -I$e -I$root/$sql -D_WIN32 -c sqlite3_drv.c
$CC -shared -o $dll/sqlite3_drv.dll sqlite3_drv.o $root/$sql/sqlite3.o $l/ei_md.lib
cd -

cd $ejdeps/esip/c_src
rm *o
$CC -I$w -I$h -I$i -I$e -D_WIN32 -c *c
$CC -shared -o $dll/esip_drv.dll esip_codec.o
cd -

cd $ejdeps/jiffy/c_src
rm *o
$CC -I$w -I$h -I$i -I$e -I. -c *c
$CCX -I$w -I$h -I$i -I$e -I. -c double-conversion/*cc doubles.cc
$CCX -shared -static-libgcc -static-libstdc++ -o $dll/jiffy.dll *o  
cd -

cd $ejdeps/cache_tab/c_src
rm *o
$CC -I$w -I$h -I$i -I$e -D_WIN32 -c *c
$CC -shared -o $dll/ets_cache.dll ets_cache.o
cd -

cd $ejdeps/xmpp/c_src
rm *o
$CC -I$w -I$h -I$i -I$e -D_WIN32 -c *c
$CC -shared -o $dll/jid.dll jid.o
$CC -shared -o $dll/xmpp_uri.dll xmpp_uri.o
cd -

#cd $ejdeps/eimp/c_src
#rm *o
#$CC -I$w -I$h -I$i -I$e -D_WIN32 -c *c
#$CC -shared -o $dll/eimp.dll eimp.o
#cd -

$ST $dll/*dll

cd bin
tar xf "$master"
unzip $dist.deps.zip
for lib in $(find $dist -name "*so")
do
  name=$(basename $lib)
  rm $lib
  cp ~/crossbuild/lib/${name/.so/.dll} $(dirname $lib)
done
cp ~/crossbuild/inotifywait.exe $(/bin/ls -d $dist/deps/fs-*/priv)
rm $dist.deps.zip
zip -9qr $dist.deps.zip $dist
rm -Rf $dist
tar cf ~/pub/bin/windows/$otp/ejabberd/$dist.epkg ${dist}*ez ${dist}*zip

echo "success: $dist.epkg generated"
