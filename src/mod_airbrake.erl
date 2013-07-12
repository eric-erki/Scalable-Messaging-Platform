%%%----------------------------------------------------------------------
%%% File    : mod_airbrake.erl
%%% Author  : Mickael Remond
%%% Purpose : Centrally upload error logs
%%%
%%% Usage:
%%% Add in module section of ejabberd config file
%%%  {mod_airbrake, [{notification_api, "https://api.rollbar.com/notifier_api/v2/notices/"},
%%%                  {apikey, "4477c24668b8466396b68289320d8681"},
%%%                  {environment, "development"}]}
%%%----------------------------------------------------------------------

-module(mod_airbrake).

-behaviour(gen_mod).

-export([start/2, stop/1]).

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
