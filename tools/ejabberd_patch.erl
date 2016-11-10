-module(ejabberd_patch).
-compile(compressed).
-export([push/1, push/4]).

-include("ejabberd_patch.hrl").

push(Node) when is_atom(Node) ->
    apply(?MODULE, push, [Node|?ARGS]).

push(Node, Vsn, Desc, Beams) ->
    log("Apply patch: ~s", [Desc]),
    case update(cluster(Node), Vsn, Beams, []) of
        [] ->
            errlog("Can not connect to ejabberd ~s", [Vsn]),
            halt(1);
        _ ->
            log("Done."),
            halt(0)
    end.

update([], _Vsn, _Beams, Acc) ->
    Acc;
update([Node|Tail], Vsn, Beams, Acc) ->
    case vsn(Node) of
        Vsn ->
            log("Updating node ~p...", [Node]),
            [copy(Node, Code) || Code <- Beams],
            update(Tail, Vsn, Beams, [Node|Acc]);
        Other ->
            errlog("Node ~p version ~s does not match ~s: IGNORED", [Node,Other,Vsn]),
            update(Tail, Vsn, Beams, Acc)
    end.

copy(Node, {Module,Beam}) ->
    case rpc:call(Node, code, which, [Module], 5000) of
        non_existing ->
            errlog("Node ~p does not have module ~s", [Node,Module]);
        Filename ->
            case rpc:call(Node, file, write_file, [Filename,Beam], 5000) of
                ok ->
                    % code:purge(Module), code:load_file(Module)
                    case rpc:call(Node, code, load_binary, [Module,Filename,Beam], 5000) of
                        {module,Module} ->
                            ok;
                        _ ->
                            errlog("Node ~p can not reload module ~s", [Node,Module])
                    end;
                _ ->
                    errlog("Node ~p can not write file ~s", [Node,Filename])
            end
    end.

cluster(Node) ->
    case rpc:call(Node, ejabberd_cluster, get_nodes, [], 5000) of
        L when is_list(L) -> L;
        _ -> []
    end.

vsn(Node) ->
    case rpc:call(Node, application, get_key, [ejabberd,vsn], 5000) of
        {ok,Vsn} -> Vsn;
        _ -> ""
    end.

log(Msg) ->
    io:format("~s~n", [Msg]).
log(Msg, Args) ->
    io:format(Msg ++ "~n", Args).
errlog(Msg, Args) ->
    log("Error: " ++ Msg, Args),
    error.
