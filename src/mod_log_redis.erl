%%%-------------------------------------------------------------------
%%% @author Jérôme Sautret <jsautret@process-one.net>
%%% @copyright (C) 2016
%%% @doc
%%% Provide remote logging to a sidekiq job via a redis base
%%% @end
%%% Created : 2016/09/16
%%%-------------------------------------------------------------------
-module(mod_log_redis).

-author('jerome.sautret@process-one.net').

% configure option --enable-logredis must be set to use this module.

% Available module parameters, with default values (all parameters are
% optional):
% * max_queue: 1000  # p1_server max queue size
% * redis_host: "127.0.0.1"
% * redis_port: 6379
% * redis_queue_size: 10
% * redis_queue_max_overflow: 30
% * sidekiq_root: "sidekiq"
% * sidekiq_queue: "default"
% * sidekiq_worker: "ConsoleLogWorker"

% /!\ If enabled on several vhosts, the following module parameters
%     MUST have the same value on all hosts:
% * redis_host
% * redis_port
% * redis_queue_size
% * redis_queue_max_overflow
% * sidekiq_queue

% API:
%
% ?REMOTE_LOG(Host, Level, Message)
% ?REMOTE_LOG(Host, Level, Format, Args,)
% ?REMOTE_LOG(Host, Level, Format, Args, Options)
%
% * Host = binary()
% * Message = Format = binary() | string()
% * Level = integer()
% * Args = [term()]
% * Options = [Option]
% * Option = sync | {tags, [Tag]}
% * Tag = binary() | string()
%
% Host is the vhost name associated with the message.
%
% Level is an integer between 0 and 5.
%
% A list of Tags can be associated to a message, if passes in the Options.
%
% By default, the call is asynchronous and returns ok.
% If Option sync is passed, then the call is synchronous and returns
% {ok, Result}, where Result is the result returned by redis.
%
% If module is not enabled or loaded, the macro returns {ok, ignored}.

-define(SIDEKIQ_ROOT, "sidekiq").
-define(SIDEKIQ_QUEUE, <<"default">>).
-define(SIDEKIQ_CLASS, <<"ConsoleLogWorker">>).
-define(SIDEKIQ_POOL, sidekiq).
-define(MAX_RETRIES, 6).

-define(REDIS_HOST, <<"127.0.0.1">>).
-define(REDIS_PORT, 6379).
-define(REDIS_QUEUE_SIZE, 10).
-define(REDIS_QUEUE_MAX_OVERFLOW, 30).

-define(DEFAULT_NAMESPACE, <<"general">>).

% API
-export([log/3, log/4, log/5]).
-export([test/3]).

-behaviour(gen_mod).
-export([start/2, stop/1,
	 mod_opt_type/1, opt_type/1, depends/2]).

-define(GEN_SERVER, p1_server).
-behaviour(?GEN_SERVER).
-export([start_link/2, init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3]).

-define(PROCNAME, ?MODULE).
% Default p1_server max queue size
-define(DEFAULT_MAX_QUEUE, 1000).
-record(state, {host, sidekiq_root, sidekiq_queue, sidekiq_worker}).

% Internal functions
-export([redis_command/2, redis_command/3]).

-include("logger.hrl").

%%%===================================================================
%%% gen_mod callbacks
%%%===================================================================

start(Host, Opts) ->
    start_redis_apps(Opts),

    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec = {Proc, {?MODULE, start_link, [Host, Opts]},
		 transient, 1000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec),
    ok.

start_redis_apps(Opts) ->
    Host = gen_mod:get_opt(redis_host, Opts,
			   fun(S) when is_binary(S) -> binary_to_list(S) end,
			   ?REDIS_HOST),
    Port = gen_mod:get_opt(redis_port, Opts,
			   fun(V) when is_integer(V) -> V end,
			   ?REDIS_PORT),
    QueueSize = gen_mod:get_opt(redis_queue_size, Opts,
			   fun(V) when is_integer(V) -> V end,
			   ?REDIS_QUEUE_SIZE),
    MaxOverflow = gen_mod:get_opt(redis_queue_max_overflow, Opts,
				  fun(V) when is_integer(V) -> V end,
				  ?REDIS_QUEUE_MAX_OVERFLOW),

    application:set_env(eredis_pool, pools,
			[{?SIDEKIQ_POOL,
			  [{size, QueueSize},
			   {max_overflow, MaxOverflow},
			   {host, Host},
			   {port, Port}
			  ]}]),
    ensure_started(eredis_pool),
    %% if eredis_pool can't be created, eredis_queue can't neither.
    Queue = gen_mod:get_opt(sidekiq_queue, Opts,
			    fun iolist_to_binary/1,
			    ?SIDEKIQ_QUEUE),
    application:set_env(eredis_queue, default_queue, Queue),
    ensure_started(eredis_queue).

ensure_started(App) ->
    case application:start(App) of
	ok ->
	    ok;
	{error, {already_started, App}} ->
	    ok;
	{error,{"no such file or directory",
		"eredis_pool.app"}} = Error->
	    ?CRITICAL_MSG("option --enable-logredis must be set"
			  " at configure time in order to use ~p", [?MODULE]),
	    throw({error, {cannot_start, App, Error}});
	Error ->
	    throw({error, {cannot_start, App, Error}})
    end.

stop(Host) ->
    %% Do NOT stop redis apps, in case module is used by several vhosts
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:call(Proc, stop),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc),
    ok.

depends(_Host, _Opts) ->
    [].

-define(IS_INTEGER, fun (V) when is_integer(V), V > 0 -> V end).
-define(IS_STRING, fun iolist_to_binary/1).

mod_opt_type(max_queue) ->
    ?IS_INTEGER;
mod_opt_type(redis_host) ->
    ?IS_STRING;
mod_opt_type(redis_port) ->
    ?IS_INTEGER;
mod_opt_type(redis_queue_size) ->
    ?IS_INTEGER;
mod_opt_type(redis_queue_max_overflow) ->
    ?IS_INTEGER;
mod_opt_type(sidekiq_root) ->
    ?IS_STRING;
mod_opt_type(sidekiq_queue) ->
    ?IS_STRING;
mod_opt_type(sidekiq_worker) ->
    ?IS_STRING;

mod_opt_type(_) -> [max_queue, redis_port, redis_port, redis_queue_size,
		    redis_queue_max_overflow, sidekiq_root, sidekiq_queue,
		    sidekiq_worker].

opt_type(_) -> [].

%%%===================================================================
%%% API
%%%===================================================================

log(Host, Level, Message) ->
    log2(Host, Level, iolist_to_binary(Message), []).

log(Host, Level, Message, Args) ->
    log(Host, Level, Message, Args, []).

log(Host, Level, Message, Args, Opts) when is_binary(Message) ->
    log(Host, Level, binary_to_list(Message), Args, Opts);

log(Host, Level, Message, Args, Opts) when is_list(Message) ->
    log2(Host, Level, iolist_to_binary(io_lib:format(Message, Args)), Opts).

log2(Host, Level, Message, Opts)
  when is_binary(Host), is_integer(Level),
       is_binary(Message), is_list(Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    case whereis(Proc) of
	undefined ->
	    % Module not started
	    {ok, ignored};
	_ ->
	    Tags = case proplists:get_value(tags, Opts, []) of
		       L when is_list(L) -> [iolist_to_binary(E) || E<-L];
		       _ -> []
		   end,
	    case proplists:get_value(sync, Opts) of
		true ->
		    ?GEN_SERVER:call(Proc, {log, Level, Tags, Message});
		_ ->
		    ?GEN_SERVER:cast(Proc, {log, Level, Tags, Message})
	    end
    end.

test(Host, Level, Message) ->
    ?REMOTE_LOG(Host, Level, Message).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

start_link(Host, Opts) ->
    MaxQueue = gen_mod:get_opt(max_queue, Opts,
			       fun(N) when is_integer(N) -> N end,
			       ?DEFAULT_MAX_QUEUE),
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:start_link({local, Proc}, ?MODULE,
			   [Host, Opts], [{max_queue, MaxQueue}]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Host, Opts]) ->
    Root = gen_mod:get_opt(sidekiq_root, Opts,
			    fun iolist_to_binary/1,
			    ?SIDEKIQ_ROOT),
    Queue = gen_mod:get_opt(sidekiq_queue, Opts,
			    fun iolist_to_binary/1,
			    ?SIDEKIQ_QUEUE),
    Class = gen_mod:get_opt(sidekiq_worker, Opts,
			    fun iolist_to_binary/1,
			    ?SIDEKIQ_CLASS),
    {ok, #state{host=Host,
		sidekiq_root=Root, sidekiq_queue=Queue, sidekiq_worker=Class}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({log, Level, Tags, Message}, _From,
	    #state{sidekiq_root=Root, sidekiq_queue=Queue,
		   sidekiq_worker=Class, host=Host} = State) ->
    Reply = sidekiq_job(Root, Queue, Class,
			[Host, Level, Tags, Message]),
    {reply, Reply, State};

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    ?WARNING_MSG("Unknown call request ~p (state ~p)", [_Request, State]),
    Reply = error,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({log, Level, Tags, Message},
	    #state{sidekiq_root=Root, sidekiq_queue=Queue,
		   sidekiq_worker=Class, host=Host} = State) ->
    sidekiq_job(Root, Queue, Class,
		[Host, Level, Tags, Message]),
    {noreply, State};

handle_cast(_Msg, State) ->
    ?WARNING_MSG("Unknown cast message ~p (state ~p)", [_Msg, State]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    ?WARNING_MSG("Unknown Info message ~p (state ~p)", [_Info, State]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% sidekiq utils
%%%===================================================================

format_job(Queue, Class, Args) ->
    {Mega, Secs, Micro} = os:timestamp(),
    Ts = Mega * 1000000 + Secs + Micro / 1000000,
    JSONParams= {[{retry, true}, {queue, Queue}, {class, Class}, {args, Args},
		  {jid, generate_job_id()}, {enqueued_at, Ts}]},
    jiffy:encode(JSONParams).

%% Example:
%% "lpush" "push_console:queue:default"
%%    "{\"retry\":true,\"queue\":\"default\",\"class\":\"ConsoleWorker\",
%%         \"args\":[302,\"deliver_email\",false],
%%         \"jid\":\"f2dc77427ea57f55b5631ca1\"}"
sidekiq_job(Root, Queue, Class, Args) ->
    Key = [Root, ":queue:", Queue],
    JSON = format_job(Queue, Class, Args),
    Command = ["LPUSH", Key, JSON],
    with_exp_backoff(?MODULE, redis_command,
		     [?SIDEKIQ_POOL, 'sidekiq_job', Command]).

generate_job_id() ->
    jlib:integer_to_binary(randoms:uniform(trunc(math:pow(10,15))), 16).

with_exp_backoff(Module, Function,  Args) ->
    with_exp_backoff(Module, Function,  Args, 0).

with_exp_backoff(Module, Function, Args, RetryCount)
  when RetryCount >= ?MAX_RETRIES ->
    apply(Module, Function, Args);
with_exp_backoff(Module, Function, Args, RetryCount) ->
    case catch apply(Module, Function, Args) of
	{ok, Result} ->
	    {ok, Result};
	Other ->
	    ?ERROR_MSG("~s:~s/~p error: ~p.  Retries left: ~p",
		       [Module, Function, length(Args),
			Other, ?MAX_RETRIES - RetryCount]),
	    NewRetryCount = RetryCount +1,
	    %% 300, 600, 1200, 2400, 4800 seconds
	    timer:sleep(round(math:pow(2, NewRetryCount))  * 150 +
			    randoms:uniform(200)),
	    with_exp_backoff(Module, Function, Args, NewRetryCount)
    end.


%%%===================================================================
%%% Redis raw commands
%%%===================================================================

%% Redis raw commands
redis_command(CommandId, Command) ->
    {ok, PoolName} = eredis_queue:get_first_poolname(),
    redis_command(PoolName, CommandId, Command).
-spec redis_command(PoolName :: atom(), Command :: iolist() ) ->
			   { string(), binary()|[binary()] } | no_return().

redis_command(PoolName, CommandId, Command) ->
	redis_command(PoolName, CommandId, Command, 0).

redis_command(_PoolName, CommandId, _Command, ConnectionClosedRetries)
  when ConnectionClosedRetries > 2 ->
    ?ERROR_MSG("Too many tcp_closed trying to send ~p to redis."
	       " Command discarded", [CommandId]),
    {error, tcp_closed};

redis_command(PoolName, CommandId, Command, ConnectionClosedRetries) ->
    case catch eredis_pool:q({global, PoolName}, Command, 10000) of
	{ok, Result} ->
	    {ok, Result};
	{error, tcp_closed} ->
	    %% Connection to redis was closed.  We must retry.
	    redis_command(PoolName, CommandId, Command,
			  ConnectionClosedRetries+1);
	{'EXIT',{noproc,{gen_server,call,_}}} ->
	    %% Connection process died between poolboy give it and
	    %% eredis_pool use it. Just retry
	    redis_command(PoolName, CommandId, Command,
			  ConnectionClosedRetries+1);
    {error, Reason} ->
	    ?ERROR_MSG("Redis command error (~p): ~p", [Reason, Command]),
	    {error, Reason};
    {'EXIT', Exit} ->
	    ?ERROR_MSG("Redis command EXIT (~p): ~p", [Exit, Command]),
	    {error, redis_pool_query_failed}
    end.
