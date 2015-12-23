#                                               -*- Autoconf -*-
# Process this file with autoconf to produce a configure script.

AC_PREREQ(2.53)
AC_INIT(ejabberd, m4_esyscmd([echo `git describe --tags 2>/dev/null || echo 3.2.x` | sed 's/-g.*//;s/-/./' | tr -d '\012']), [ejabberd@process-one.net], [ejabberd])
REQUIRE_ERLANG_MIN="6.1 (Erlang/OTP 17.1)"
REQUIRE_ERLANG_MAX="9.0.0 (No Max)"

AC_CONFIG_MACRO_DIR([m4])

# Checks for programs.
AC_PROG_CC
AC_PROG_MAKE_SET
AC_PROG_INSTALL
AC_PROG_SED

if test "x$GCC" = "xyes"; then
    CFLAGS="$CFLAGS -Wall"
fi

# Checks for typedefs, structures, and compiler characteristics.
AC_C_CONST

# Checks for library functions.
AC_FUNC_MALLOC
AC_HEADER_STDC

# Checks Erlang runtime and compiler
AC_ARG_WITH(erlang,
	AC_HELP_STRING([--with-erlang=dir],
		[search for erlang in dir]),
[if test "$withval" = "yes" -o "$withval" = "no" -o "X$with_erlang" = "X"; then
    extra_erl_path=""
else
    extra_erl_path="$with_erlang:$with_erlang/bin:"
fi
])

# Check licence value
LICENCE="21280610"  # translates to 9999 default value.
AC_ARG_WITH(licence,
	AC_HELP_STRING([--with-licence=date],
		[apply licence up to given date in YYYYMMDD format]),
[if test "$withval" = "yes" -o "$withval" = "no" -o "X$with_licence" = "X"; then
    LICENCE=$(date -j -v+1w +%Y%m%d)  # if no date passed, give one week licence
else
    LICENCE="$with_licence"
    if test ${#LICENCE} -ne 8; then
        echo "invalid licence format: $LICENCE"
        exit 8
    fi
fi
])
AC_SUBST([PACKAGE_LICENCE], [${LICENCE:0:4},${LICENCE:4:2},${LICENCE:6:2}])

AC_PATH_TOOL(ERL, erl, , [${extra_erl_path}$PATH])
AC_PATH_TOOL(ERLC, erlc, , [${extra_erl_path}$PATH])

AC_ERLANG_NEED_ERL
AC_ERLANG_NEED_ERLC

AC_ARG_ENABLE(erlang-version-check,
[AC_HELP_STRING([--enable-erlang-version-check],
	[Check Erlang/OTP version @<:@default=yes@:>@])])
	case "$enable_erlang_version_check" in
	yes|'')
		ERLANG_VERSION_CHECK([$REQUIRE_ERLANG_MIN],[$REQUIRE_ERLANG_MAX])
		;;
	no)
		ERLANG_VERSION_CHECK([$REQUIRE_ERLANG_MIN],[$REQUIRE_ERLANG_MAX],[warn])
		;;
esac

# Checks and sets ERLANG_ROOT_DIR and ERLANG_LIB_DIR variable
AC_ERLANG_SUBST_ROOT_DIR
# AC_ERLANG_SUBST_LIB_DIR

#locating escript
AC_PATH_PROG([ESCRIPT], [escript], [], [$ERLANG_ROOT_DIR/bin])

#locating make
AC_CHECK_PROG([MAKE], [make], [make], [])

if test "x$ESCRIPT" = "x"; then
   AC_MSG_ERROR(['escript' was not found])
fi

if test "x$MAKE" = "x"; then
   AC_MSG_ERROR(['make' was not found])
fi

# Change default prefix
AC_PREFIX_DEFAULT(/)

AC_ARG_ENABLE(hipe,
[AC_HELP_STRING([--enable-hipe], [compile natively with HiPE, not recommended (default: no)])],
[case "${enableval}" in
  yes) hipe=true ;;
  no)  hipe=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-hipe) ;;
esac],[hipe=false])

AC_ARG_ENABLE(roster_gateway_workaround,
[AC_HELP_STRING([--enable-roster-gateway-workaround], [turn on workaround for processing gateway subscriptions (default: no)])],
[case "${enableval}" in
  yes) roster_gateway_workaround=true ;;
  no)  roster_gateway_workaround=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-roster-gateway-workaround) ;;
esac],[roster_gateway_workaround=false])

AC_ARG_ENABLE(flash_hack,
[AC_HELP_STRING([--enable-flash-hack], [support Adobe Flash client XML (default: no)])],
[case "${enableval}" in
  yes) flash_hack=true ;;
  no)  flash_hack=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-flash-hack) ;;
esac],[flash_hack=false])

AC_ARG_ENABLE(full_xml,
[AC_HELP_STRING([--enable-full-xml], [use XML features in XMPP stream (ex: CDATA) (default: no, requires XML compliant clients)])],
[case "${enableval}" in
  yes) full_xml=true ;;
  no)  full_xml=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-full-xml) ;;
esac],[full_xml=false])

AC_ARG_ENABLE(mssql,
[AC_HELP_STRING([--enable-mssql], [use Microsoft SQL Server database (default: no, requires --enable-odbc)])],
[case "${enableval}" in
  yes) db_type=mssql ;;
  no)  db_type=generic ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-mssql) ;;
esac],[db_type=generic])

AC_ARG_ENABLE(all,
[AC_HELP_STRING([--enable-all], [same as --enable-odbc --enable-mysql --enable-pgsql --enable-sqlite --enable-pam --enable-zlib --enable-riak --enable-redis --enable-elixir --enable-iconv --enable-debug --enable-http --enable-lager --enable-tools --enable-p1db (useful for Dialyzer checks, default: no)])],
[case "${enableval}" in
  yes) odbc=true mysql=true pgsql=true sqlite=true pam=true zlib=true riak=true redis=true elixir=true iconv=true debug=true http=true lager=true tools=true p1db=true ;;
  no) odbc=false mysql=false pgsql=false sqlite=false pam=false zlib=false riak=false redis=false elixir=false iconv=false debug=false http=false lager=false tools=false p1db=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-all) ;;
esac],[])

AC_ARG_ENABLE(tools,
[AC_HELP_STRING([--enable-tools], [build development tools (default: no)])],
[case "${enableval}" in
  yes) tools=true ;;
  no)  tools=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-tools) ;;
esac],[if test "x$tools" = "x"; then tools=false; fi])

AC_ARG_ENABLE(odbc,
[AC_HELP_STRING([--enable-odbc], [enable pure ODBC support (default: no)])],
[case "${enableval}" in
  yes) odbc=true ;;
  no)  odbc=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-odbc) ;;
esac],[if test "x$odbc" = "x"; then odbc=false; fi])

AC_ARG_ENABLE(mysql,
[AC_HELP_STRING([--enable-mysql], [enable MySQL support (default: no)])],
[case "${enableval}" in
  yes) mysql=true ;;
  no)  mysql=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-mysql) ;;
esac],[if test "x$mysql" = "x"; then mysql=false; fi])

AC_ARG_ENABLE(pgsql,
[AC_HELP_STRING([--enable-pgsql], [enable PostgreSQL support (default: no)])],
[case "${enableval}" in
  yes) pgsql=true ;;
  no)  pgsql=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-pgsql) ;;
esac],[if test "x$pgsql" = "x"; then pgsql=false; fi])

AC_ARG_ENABLE(sqlite,
[AC_HELP_STRING([--enable-sqlite], [enable SQLite support (default: no)])],
[case "${enableval}" in
  yes) sqlite=true ;;
  no)  sqlite=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-sqlite) ;;
esac],[if test "x$sqlite" = "x"; then sqlite=false; fi])

AC_ARG_ENABLE(pam,
[AC_HELP_STRING([--enable-pam], [enable PAM support (default: no)])],
[case "${enableval}" in
  yes) pam=true ;;
  no)  pam=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-pam) ;;
esac],[if test "x$pam" = "x"; then pam=false; fi])

AC_ARG_ENABLE(zlib,
[AC_HELP_STRING([--enable-zlib], [enable Stream Compression (XEP-0138) using zlib (default: yes)])],
[case "${enableval}" in
  yes) zlib=true ;;
  no)  zlib=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-zlib) ;;
esac],[if test "x$zlib" = "x"; then zlib=true; fi])

AC_ARG_ENABLE(riak,
[AC_HELP_STRING([--enable-riak], [enable Riak support (default: no)])],
[case "${enableval}" in
  yes) riak=true ;;
  no)  riak=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-riak) ;;
esac],[if test "x$riak" = "x"; then riak=false; fi])

AC_ARG_ENABLE(redis,
[AC_HELP_STRING([--enable-redis], [enable Redis support (default: no)])],
[case "${enableval}" in
  yes) redis=true ;;
  no)  redis=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-redis) ;;
esac],[if test "x$redis" = "x"; then redis=false; fi])

AC_ARG_ENABLE(p1db,
[AC_HELP_STRING([--enable-p1db], [enable P1DB support (default: no)])],
[case "${enableval}" in
  yes) p1db=true ;;
  no)  p1db=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-p1db) ;;
esac],[if test "x$p1db" = "x"; then p1db=false; fi])

AC_ARG_ENABLE(elixir,
[AC_HELP_STRING([--enable-elixir], [enable Elixir support (default: no)])],
[case "${enableval}" in
  yes) elixir=true ;;
  no)  elixir=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-elixir) ;;
esac],[if test "x$elixir" = "x"; then elixir=false; fi])

AC_ARG_ENABLE(iconv,
[AC_HELP_STRING([--enable-iconv], [enable iconv support (default: yes)])],
[case "${enableval}" in
  yes) iconv=true ;;
  no)  iconv=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-iconv) ;;
esac],[if test "x$iconv" = "x"; then iconv=true; fi])

AC_ARG_ENABLE(debug,
[AS_HELP_STRING([--enable-debug[[[[=INFOKEY]]]]], [enable debug information with optional encrypt key (default: yes)])],
[case "${enableval}" in
  yes) debug=true ;;
  no)  debug=false ;;
  *)   debug="\"$enableval\"" ;;
esac],[if test "x$debug" = "x"; then debug=true; fi])

AC_ARG_ENABLE(pubsub_ng,
[AC_HELP_STRING([--enable-pubsub-ng], [enable PubSub NG (default: no)])],
[case "${enableval}" in
  yes) pubsub_ng=true ;;
  no)  pubsub_ng=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-pubsub-ng) ;;
esac],[if test "x$pubsub_ng" = "x"; then pubsub_ng=false; fi])

AC_ARG_ENABLE(http,
[AC_HELP_STRING([--enable-http], [build external HTTP libraries ('ibrowse' and 'lhttpc', default: no)])],
[case "${enableval}" in
  yes) http=true ;;
  no)  http=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-http) ;;
esac],[if test "x$http" = "x"; then http=false; fi])

AC_ARG_ENABLE(lager,
[AC_HELP_STRING([--enable-lager], [enable lager support (default: yes)])],
[case "${enableval}" in
  yes) lager=true ;;
  no)  lager=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-lager) ;;
esac],[if test "x$lager" = "x"; then lager=true; fi])

AC_ARG_ENABLE(airbrake,
[AC_HELP_STRING([--enable-airbrake], [enable Airbrake notification (default: no)])],
[case "${enableval}" in
  yes) airbrake=true ;;
  no)  airbrake=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-airbrake) ;;
esac],[if test "x$airbrake" = "x"; then airbrake=false; fi])
AC_ARG_ENABLE(latest_deps,
[AC_HELP_STRING([--enable-latest-deps], [makes rebar use latest commits for dependences instead of tagged versions (default: no)])],
[case "${enableval}" in
  yes) latest_deps=true ;;
  no)  latest_deps=false ;;
  *) AC_MSG_ERROR(bad value ${enableval} for --enable-latest-deps) ;;
esac],[if test "x$latest_deps" = "x"; then latest_deps=false; fi])

AC_CONFIG_FILES([Makefile
		 vars.config
		 src/ejabberd.app.src])

ENABLEUSER=""
AC_ARG_ENABLE(user,
  [AS_HELP_STRING([--enable-user[[[[=USER]]]]], [allow this system user to start ejabberd (default: no)])],
  [case "${enableval}" in
     yes) ENABLEUSER=`whoami` ;;
     no) ENABLEUSER="" ;;
     *) ENABLEUSER=$enableval
   esac],
  [])
if test "$ENABLEUSER" != ""; then
  echo "allow this system user to start ejabberd: $ENABLEUSER"
  AC_SUBST([INSTALLUSER], [$ENABLEUSER])
fi

ERLANG_DEPRECATED_TYPES_CHECK

if test "$sqlite" = "true"; then
   AX_LIB_SQLITE3([3.6.19])
   if test "x$SQLITE3_VERSION" = "x"; then
      AC_MSG_ERROR(SQLite3 library >= 3.6.19 was not found)
   fi
fi

AC_SUBST(hipe)
AC_SUBST(roster_gateway_workaround)
AC_SUBST(flash_hack)
AC_SUBST(full_xml)
AC_SUBST(db_type)
AC_SUBST(odbc)
AC_SUBST(mysql)
AC_SUBST(pgsql)
AC_SUBST(sqlite)
AC_SUBST(pam)
AC_SUBST(zlib)
AC_SUBST(riak)
AC_SUBST(redis)
AC_SUBST(p1db)
AC_SUBST(elixir)
AC_SUBST(iconv)
AC_SUBST(debug)
AC_SUBST(pubsub_ng)
AC_SUBST(http)
AC_SUBST(lager)
AC_SUBST(tools)
AC_SUBST(airbrake)
AC_SUBST(latest_deps)
AC_SUBST(CFLAGS)
AC_SUBST(CPPFLAGS)
AC_SUBST(LDFLAGS)

AC_OUTPUT
