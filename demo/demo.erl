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

recv(_Pid, _Sid, {json, <<>>, Json}, SessionState = #session_state{}) ->
    error_logger:info_msg("recv json ~p~n", [Json]),
    demo_mgr:publish_to_all(Json),
    {ok, SessionState};

recv(Pid, _Sid, {message, <<>>, Message}, SessionState = #session_state{}) ->
    engineio_session:send_message(Pid, Message),
    {ok, SessionState};

recv(_Pid, _Sid, {event, _EndPoint, EventName, ArgsList}, SessionState = #session_state{}) ->
    error_logger:info_msg("recv event~nname: ~p~nargs: ~p~n", [EventName, ArgsList]),
    demo_mgr:emit_to_all(EventName, ArgsList),
    {ok, SessionState};

recv(Pid, Sid, Message, SessionState = #session_state{}) ->
    error_logger:info_msg("recv ~p ~p ~p~n", [Pid, Sid, Message]),
    {ok, SessionState}.

handle_info(_Pid, _Sid, _Info, SessionState = #session_state{}) ->
    {ok, SessionState}.

close(Pid, Sid, _SessionState = #session_state{}) ->
    error_logger:info_msg("close ~p ~p~n", [Pid, Sid]),
    demo_mgr:remove_session(Pid),
    ok.
