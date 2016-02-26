#!/bin/sh

# This must be running from same binary environment as we build installers:
# ssh cean@build.vpn.p1
# prod64
# cd ~/crossbuild
# ~/.crossbuild.sh

root=~/crossbuild
dll=$root/lib
cd $root

ejsrc=ejabberd
ejdeps=$root/$ejsrc/deps

zlib=zlib-1.2.8
expat=expat-2.1.0
yaml=yaml-0.1.5
ssl=openssl-1.0.2f
iconv=libiconv-1.14
sql=sqlite-autoconf-3081002

CHOST=x86_64-w64-mingw32
CC=$CHOST-gcc
CCX=$CHOST-g++
LD=$CHOST-ld
AR=$CHOST-ar
RC=$CHOST-windres
ST=$CHOST-strip
w=/usr/$CHOST/include
i=$root/erl6.4/usr/include
h=$CEAN_ROOT/src/otp/erts/emulator/sys/win32
e=$CEAN_ROOT/src/otp/lib/erl_interface/include

mkdir -p $dll
(cd $ejsrc
 ./autogen.sh
 ./configure --enable-mysql --enable-pgsql --enable-sqlite --enable-riak --enable-redis --enable-elixir
 ./rebar get-deps)

cd $ejdeps/ezlib/c_src
rm *o
$CC -I$w -I$h -I$i -I$e -I$root/$zlib -D_WIN32 -c ezlib_drv.c
$CC -shared -o $dll/ezlib_drv.dll ezlib_drv.o $dll/ei_md.lib $dll/zlib1.dll
cd -

cd $ejdeps/stringprep/c_src
rm *o
$CC -I$w -I$h -I$i -I$e -D_WIN32 -c *c
$CCX -I$w -I$h -I$i -I$e -D_WIN32 -c *cpp
$CCX -shared -static-libgcc -static-libstdc++ -o $dll/stringprep.dll *o
cd -

cd $ejdeps/fast_xml/c_src
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

cd $ejdeps/fast_tls/c_src
rm *o
[ -d $root/$ssl ] || curl https://www.openssl.org/source/$ssl.tar.gz | tar -C $root -zxf -
(cd $root/$ssl; ./Configure mingw64; make CC=$CHOST-gcc; $CHOST-ranlib *.a)
$CC -I$w -I$h -I$i -I$e -I$root/$ssl/include -D_WIN32 -c p1_sha.c fast_tls_drv.c
$CC -shared -o $dll/p1_sha.dll p1_sha.o $root/$ssl/libcrypto.a
$CC -shared -o $dll/fast_tls_drv.dll fast_tls_drv.o $root/$ssl/libssl.a $root/$ssl/libcrypto.a /usr/$CHOST/lib/libgdi32.a /usr/$CHOST/lib/libwsock32.a
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
$CC -shared -o $dll/sqlite3_drv.dll sqlite3_drv.o $root/$sql/sqlite3.o $dll/ei_md.lib
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

$ST $dll/*dll
