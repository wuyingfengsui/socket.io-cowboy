-module(demo).

-export([start/0, open/4, recv/4, handle_info/4, close/3]).

-record(session_state, {}).

start() ->
    ok = mnesia:start(),
    ok = engineio_session:init_mnesia(),
    ok = engineio:start(),

    Dispatch = cowboy_router:compile([
        {'_', [
            {"/engine.io/[...]", engineio_handler, [engineio_session:configure([{heartbeat, 25000},
                {heartbeat_timeout, 60000},
                {session_timeout, 60000},
                {callback, ?MODULE}])]
            },
            {"/[...]", cowboy_static, {dir, <<"./priv">>, [{mimetypes, cow_mimetypes, web}]}}
        ]}
    ]),

    demo_mgr:start_link(),

    cowboy:start_http(engineio_http_listener, 100, [{host, "127.0.0.1"},
        {port, 8080}], [{env, [{dispatch, Dispatch}]}]).

%% ---- Handlers
open(Pid, Sid, _Opts, _PeerAddress) ->
    error_logger:info_msg("open ~p ~p~n", [Pid, Sid]),
    demo_mgr:add_session(Pid),
    {ok, #session_state{}}.

recv(Pid, Sid, {message, Message}, SessionState) ->
    %error_logger:info_msg("recv first ~p ~p ~p~n", [Pid, Sid, Message]),
    demo_mgr:publish_to_all(Message),
    {ok, SessionState}.

handle_info(_Pid, _Sid, _Info, SessionState = #session_state{}) ->
    {ok, SessionState}.

close(Pid, Sid, _SessionState = #session_state{}) ->
    error_logger:info_msg("close ~p ~p~n", [Pid, Sid]),
    demo_mgr:remove_session(Pid),
    ok.
