%%%----------------------------------------------------------------------
%%% File    : mod_airbrake.erl
%%% Author  : Mickael Remond <mremond@process-one.net>
%%% Purpose : Centrally upload error logs
%%% Created :
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2017   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

%%% Usage:
%%% Add in module section of ejabberd config file
%%%  mod_airbrake:
%%%    notification_api: "https://api.rollbar.com/notifier_api/v2/notices/"
%%%    apikey: "4477c24668b8466396b68289320d8681"
%%%    environment: "development"

-module(mod_airbrake).

-behaviour(gen_mod).

-export([start/2, stop/1, depends/2, mod_opt_type/1]).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("logger.hrl").

-define(NOTIFICATION_API, "http://airbrake.io/notifier_api/v2/notices").

-define(ENVIRONMENT, "Development").

start(_Host, Opts) ->
    NotificationApi = gen_mod:get_opt(notification_api, Opts,
                                      fun check_fun/1, ?NOTIFICATION_API),
    ApiKey = gen_mod:get_opt(apikey, Opts, fun check_fun/1),
    Environment = gen_mod:get_opt(environment, Opts,
                                  fun check_fun/1, ?ENVIRONMENT),
    case ApiKey of
        undefined ->
            ?ERROR_MSG("Cannot start mod_airbrake: Missing apikey", []);
        _ ->
            application:load(erlbrake),
            application:set_env(erlbrake, notification_api, NotificationApi),
            application:set_env(erlbrake, apikey, ApiKey),
            application:set_env(erlbrake, environment, Environment),
            application:set_env(erlbrake, error_logger, true),
            ejabberd:start_app(erlbrake)
    end.

stop(_Host) -> ok.

check_fun(S) ->
    binary_to_list(iolist_to_binary(S)).

depends(_Host, _Opts) ->
    [].

mod_opt_type(apikey) -> fun check_fun/1;
mod_opt_type(environment) -> fun check_fun/1;
mod_opt_type(notification_api) -> fun check_fun/1;
mod_opt_type(_) ->
    [apikey, environment, notification_api].
