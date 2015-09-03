%% @author Kirill Trofimov <sinnus@gmail.com>
%% @copyright 2012 Kirill Trofimov
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%    http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
-module(socketio_handler).
-author('Kirill Trofimov <sinnus@gmail.com>').
-include("socketio_internal.hrl").

-export([init/2, terminate/3,
         info/3,
         websocket_handle/3, websocket_info/3]).

-record(http_state, {action, config, sid, heartbeat_tref, messages, pid, version, jsonp, loop = false}).
-record(websocket_state, {config, pid, messages, version}).

init(Req, [Config]) ->
    Req2 = enable_cors(Req),
    ?DBGPRINT(Req2),
    PathInfo = cowboy_req:path_info(Req2),
    ?DBGPRINT(PathInfo),
    case PathInfo of
        [<<"1">>] ->
            handle(Req2, #http_state{action = create_session, config = Config, version = 0});
        [<<"1">>, <<"xhr-polling">>, Sid] ->
            handle_polling(Req2, Sid, Config, 0, undefined);
        [<<"1">>, <<"websocket">>, _Sid] ->
            websocket_init(PathInfo, Req, Config);
        _ ->
            KeyValues = cowboy_req:parse_qs(Req2),
            Sid = proplists:get_value(<<"sid">>, KeyValues),
            Transport = proplists:get_value(<<"transport">>, KeyValues),
            JsonP = proplists:get_value(<<"j">>, KeyValues),
            case {Transport, Sid} of
                {<<"polling">>, undefined} ->
                    handle(Req2, #http_state{action = create_session, config = Config, version = 1, jsonp = JsonP});
                {<<"polling">>, _} when is_binary(Sid) ->
                    handle_polling(Req2, Sid, Config, 1, JsonP);
                {<<"websocket">>, _} ->
                    websocket_init(PathInfo, Req, Config);
                _ ->
                    handle(Req2, #http_state{config = Config})
            end
    end.

%% Http handlers
handle(Req, HttpState = #http_state{action = create_session, version = Version, jsonp = JsonP, config = #config{
    heartbeat = HeartbeatInterval,
    heartbeat_timeout = HeartbeatTimeout,
    session_timeout = SessionTimeout,
    opts = Opts,
    callback = Callback
}}) ->
    Sid = uuids:new(),
    PeerAddress = cowboy_req:peer(Req),

    _Pid = socketio_session:create(Sid, SessionTimeout, Callback, Opts, PeerAddress),

    case Version of
        0 ->
            HeartbeatTimeoutBin = list_to_binary(integer_to_list(HeartbeatTimeout div 1000)),
            SessionTimeoutBin = list_to_binary(integer_to_list(SessionTimeout div 1000)),

            Result = <<":", HeartbeatTimeoutBin/binary, ":", SessionTimeoutBin/binary, ":websocket,xhr-polling">>,
            Result2 = <<Sid/binary, Result/binary>>,

            Req1 = cowboy_req:reply(200, text_headers(), <<Result2/binary>>, Req);
        1 ->
            Result = jiffy:encode({[
                {<<"sid">>, Sid},
                {<<"pingInterval">>, HeartbeatInterval}, {<<"pingTimeout">>, HeartbeatTimeout},
                {<<"upgrades">>, []}  %[<<"websocket">>]}
            ]}),

            case JsonP of
                undefined ->
                    ResultLen = [ list_to_integer([D]) || D <- integer_to_list(byte_size(Result) + 1) ],
                    ResultLenBin = list_to_binary(ResultLen),
                    Result2 = <<0, ResultLenBin/binary, 255, "0", Result/binary>>,
                    HttpHeaders = stream_headers();
                Num ->
                    ResultLenBin = integer_to_binary(byte_size(Result) + 1),
                    Rs = binary:replace(Result, <<"\"">>, <<"\\\"">>, [global]),
                    Result2 = <<"___eio[", Num/binary, "](\"", ResultLenBin/binary, ":0", Rs/binary, "\");">>,
                    HttpHeaders = javascript_headers()
            end,

            Req1 = cowboy_req:reply(200, HttpHeaders, <<Result2/binary>>, Req)
    end,
    {ok_or_stop(HttpState), Req1, HttpState};

handle(Req, HttpState = #http_state{action = data, messages = Messages, config = Config, version = Version, jsonp = JsonP}) ->
    {ok, Req1} = reply_messages(Req, Messages, Config, false, Version, JsonP),
    {ok_or_stop(HttpState), Req1, HttpState};

handle(Req, HttpState = #http_state{action = not_found}) ->
    Req1 = cowboy_req:reply(404, [], <<>>, Req),
    {ok_or_stop(HttpState), Req1, HttpState};

handle(Req, HttpState = #http_state{action = send}) ->
    Req1 = cowboy_req:reply(200, [], <<>>, Req),
    {ok_or_stop(HttpState), Req1, HttpState};

handle(Req, HttpState = #http_state{action = session_in_use}) ->
    Req1 = cowboy_req:reply(404, [], <<>>, Req),
    {ok_or_stop(HttpState), Req1, HttpState};

handle(Req, HttpState = #http_state{action = ok, version = 1}) ->
    Req1 = cowboy_req:reply(200, text_headers(), <<"ok">>, Req),
    {ok_or_stop(HttpState), Req1, HttpState};
handle(Req, HttpState = #http_state{action = ok}) ->
    Req1 = cowboy_req:reply(200, text_headers(), <<>>, Req),
    {ok_or_stop(HttpState), Req1, HttpState};

handle(Req, HttpState) ->
    Req1 = cowboy_req:reply(404, [], <<>>, Req),
    {ok_or_stop(HttpState), Req1, HttpState}.

info({timeout, TRef, {?MODULE, Pid}}, Req, HttpState = #http_state{action = heartbeat, heartbeat_tref = TRef}) ->
    safe_poll(Req, HttpState#http_state{heartbeat_tref = undefined}, Pid, false);

info({message_arrived, Pid}, Req, HttpState = #http_state{action = heartbeat}) ->
    safe_poll(Req, HttpState, Pid, true);

info(_Info, Req, HttpState) ->
    {ok, Req, HttpState}.

terminate(_Reason, _Req, _HttpState = #http_state{action = create_session}) ->
    ok;
terminate(_Reason, _Req, _HttpState = #http_state{action = session_in_use}) ->
    ok;
terminate(_Reason, _Req, _HttpState = #http_state{heartbeat_tref = HeartbeatTRef, pid = Pid}) ->
    safe_unsub_caller(Pid, self()),
    case HeartbeatTRef of
        undefined ->
            ok;
        _ ->
            erlang:cancel_timer(HeartbeatTRef)
    end;
terminate(_Reason, _Req, #websocket_state{pid = Pid}) ->
    socketio_session:disconnect(Pid),
    ok.

text_headers() ->
    [
        {<<"Content-Type">>, <<"text/plain; charset=utf-8">>}
    ].

stream_headers() ->
    [
        {<<"Content-Type">>, <<"application/octet-stream">>}
    ].

javascript_headers() ->
    [
        {<<"Content-Type">>, <<"text/javascript; charset=UTF-8">>},
        {<<"X-XSS-Protection">>, <<"0">>}
    ].

reply_messages(Req, Messages, _Config = #config{protocol = Protocol}, SendNop, 1, undefined) ->
    PacketList = case {SendNop, Messages} of
                 {true, []} ->
                     Protocol:encode_v1([nop]);
                 _ ->
                     Protocol:encode_v1(Messages)
             end,
    PacketListBin = encode_polling_xhr_packets_v1(PacketList),
    cowboy_req:reply(200, stream_headers(), PacketListBin, Req);

reply_messages(Req, Messages, _Config = #config{protocol = Protocol}, SendNop, 1, JsonP) ->
    PacketList = case {SendNop, Messages} of
                     {true, []} ->
                         Protocol:encode_v1([nop]);
                     _ ->
                         Protocol:encode_v1(Messages)
                 end,
    PacketListBin = encode_polling_json_packets_v1(PacketList, JsonP),
    cowboy_req:reply(200, javascript_headers(), PacketListBin, Req);

reply_messages(Req, Messages, _Config = #config{protocol = Protocol}, SendNop, 0, _JsonP) ->
    Packet = case {SendNop, Messages} of
                 {true, []} ->
                     Protocol:encode([nop]);
                 _ ->
                     Protocol:encode(Messages)
             end,
    cowboy_req:reply(200, text_headers(), Packet, Req).

safe_unsub_caller(undefined, _Caller) ->
    ok;

safe_unsub_caller(_Pid, undefined) ->
    ok;

safe_unsub_caller(Pid, Caller) ->
    try
        socketio_session:unsub_caller(Pid, Caller),
        ok
    catch
        exit:{noproc, _} ->
            error
    end.

safe_poll(Req, HttpState = #http_state{config = Config, version = Version, jsonp = JsonP}, Pid, WaitIfEmpty) ->
    try
        Messages = socketio_session:poll(Pid),
        case {WaitIfEmpty, Messages} of
            {true, []} when Version =:= 1 ->
                case socketio_session:transport(Pid) of
                    websocket ->
                        {ok, Req1} = reply_messages(Req, [], Config, true, Version, JsonP),
                        {ok, Req1, HttpState};
                    _ ->
                        % Always 'ok', never 'stop' for loop handler.
                        {ok, Req, HttpState, hibernate}
                end;
            {true, []} ->
                % Always 'ok', never 'stop' for loop handler.
                {ok, Req, HttpState, hibernate};
            _ ->
                {ok, Req1} = reply_messages(Req, Messages, Config, true, Version, JsonP),
                {ok_or_stop(HttpState), Req1, HttpState}
        end
    catch
        exit:{noproc, _} ->
            RD = cowboy_req:reply(404, [], <<>>, Req),
            {ok_or_stop(HttpState), RD, HttpState#http_state{action = disconnect}}
    end.

% Used to decide whether to return 'ok' or 'stop' as the first entry in the
% return tuple, when a response has been sent. If we're a loop handler, we're
% supposed to return 'stop' after a response was sent.
ok_or_stop(HttpState = #http_state{loop = Loop}) ->
    ?DBGPRINT(HttpState),
    case Loop of
        true -> ok; %stop;
        _ -> ok
    end.

handle_polling(Req, Sid, Config, Version, JsonP) ->
    Method = cowboy_req:method(Req),
    case {socketio_session:find(Sid), Method} of
        {{ok, Pid}, <<"GET">>} ->
            case socketio_session:pull_no_wait(Pid, self()) of
                {error, noproc} ->
                    {ok, cowboy_req:reply(400, <<"Can't upgrade">>, Req), #http_state{action = error, config = Config, sid = Sid, version = Version, jsonp = JsonP}};
                session_in_use ->
                    {ok, cowboy_req:reply(400, <<"Can't upgrade">>, Req), #http_state{action = error, config = Config, sid = Sid, version = Version, jsonp = JsonP}};
                [] when Version =:= 1 ->
                    case socketio_session:transport(Pid) of
                        websocket ->
                            {ok, Req, #http_state{action = data, messages = [nop], config = Config, sid = Sid, pid = Pid, version = Version, jsonp = JsonP}};
                        _ ->
                            {cowboy_loop, Req, #http_state{action = heartbeat, config = Config, sid = Sid, pid = Pid, version = Version, jsonp = JsonP, loop = true}, hibernate}
                    end;
                [] when Version =:= 0 ->
                    HeartBeatTimer = erlang:send_after(Config#config.heartbeat, self(), {?MODULE, Pid}),
                    {cowboy_loop, Req, #http_state{action = heartbeat, heartbeat_tref = HeartBeatTimer, config = Config, sid = Sid, pid = Pid, version = Version, jsonp = JsonP, loop = true}, hibernate};
                Messages ->
                    {ok, Req, #http_state{action = data, messages = Messages, config = Config, sid = Sid, pid = Pid, version = Version, jsonp = JsonP}}
            end;
        {{ok, Pid}, <<"POST">>} ->
            case get_request_data(Req, JsonP) of
                {ok, Data2, Req2} ->
                    Protocol = Config#config.protocol,
                    DecodeMethod = case Version of
                                0 -> decode;
                                1 -> decode_v1
                            end,

                    Messages = case catch(Protocol:DecodeMethod(Data2)) of
                                   {'EXIT', _Reason} ->
                                       [];
                                   {error, _Reason} ->
                                       [];
                                   Msgs ->
                                       Msgs
                               end,
                    case socketio_session:recv(Pid, Messages) of
                        noproc ->
                            {ok, cowboy_req:reply(400, <<"Can't upgrade">>, Req2), #http_state{action = error, config = Config, sid = Sid, version = Version, jsonp = JsonP}};
                        _ ->
                            {ok, Req2, #http_state{action = ok, config = Config, sid = Sid, version = Version, jsonp = JsonP}}
                    end;
                error ->
                    {ok, cowboy_req:reply(400, <<"Can't upgrade">>, Req), #http_state{action = error, config = Config, sid = Sid, version = Version}}
            end;
        {{error, not_found}, _} ->
            {ok, Req, #http_state{action = not_found, sid = Sid, config = Config, version = Version, jsonp = JsonP}};
        _ ->
            {ok, Req, #http_state{action = error, sid = Sid, config = Config, version = Version, jsonp = JsonP}}
    end.

%% Websocket handlers
websocket_init(PathInfo, Req, Config) ->
    case PathInfo of
        [<<"1">>, <<"websocket">>, Sid] ->
            case socketio_session:find(Sid) of
                {ok, Pid} ->
                    erlang:monitor(process, Pid),
                    self() ! go,
                    erlang:start_timer(Config#config.heartbeat, self(), {?MODULE, Pid}),
                    {cowboy_websocket, Req, #websocket_state{config = Config, pid = Pid, messages = [], version = 0}, hibernate};
                {error, not_found} ->
                    {ok, cowboy_req:reply(500, <<"No such session">>, Req)}
            end;
        _ ->
            KeyValues = cowboy_req:parse_qs(Req),
            case proplists:get_value(<<"sid">>, KeyValues, undefined) of
                Sid when is_binary(Sid) ->
                    case socketio_session:find(Sid) of
                        {ok, Pid} ->
                            erlang:monitor(process, Pid),
                            socketio_session:upgrade_transport(Pid, websocket),
                            {cowboy_websocket, Req, #websocket_state{config = Config, pid = Pid, messages = [], version = 1}, hibernate};
                        {error, not_found} ->
                            {ok, cowboy_req:reply(500, <<"No such session">>, Req)}
                    end;
                _ ->
                    {ok, cowboy_req:reply(500, <<"No such session">>, Req)}
            end
    end.

websocket_handle({text, Data}, Req, State = #websocket_state{
    config = #config{protocol = Protocol}, pid = Pid, version = Version
}) ->
    DecodeMethod = case Version of
                       0 -> decode;
                       1 -> decode_v1_for_websocket
                   end,
    case catch (Protocol:DecodeMethod(Data)) of
        {'EXIT', _Reason} ->
            {ok, Req, State, hibernate};
        [{ping, Rest}] ->               %% only for socketio v1
            Packet = Protocol:encode_v1({pong, Rest}),
            socketio_session:refresh(Pid),
            {reply, {text, Packet}, Req, State, hibernate};
        [upgrade] ->                    %% only for socketio v1
            self() ! go,
            {ok, Req, State, hibernate};
        Msgs ->
            case socketio_session:recv(Pid, Msgs) of
                noproc ->
                    {shutdown, Req, State};
                _ ->
                    {ok, Req, State, hibernate}
            end
    end;
websocket_handle(_Data, Req, State) ->
    {ok, Req, State, hibernate}.

websocket_info(go, Req, State = #websocket_state{pid = Pid, messages = RestMessages}) ->
    case socketio_session:pull(Pid, self()) of
        {error, noproc} ->
            {shutdown, Req, State};
        session_in_use ->
            {ok, Req, State, hibernate};
        Messages ->
            RestMessages2 = lists:append([RestMessages, Messages]),
            self() ! go_rest,
            {ok, Req, State#websocket_state{messages = RestMessages2}, hibernate}
    end;
websocket_info(go_rest, Req, State = #websocket_state{
    config = #config{protocol = Protocol}, messages = RestMessages, version = Version
}) ->
    case RestMessages of
        [] ->
            {ok, Req, State, hibernate};
        [Message | Rest] ->
            self() ! go_rest,

            Packet = case Version of
                         0 ->
                             Protocol:encode(Message);
                         1 ->
                             [Pkg] = Protocol:encode_v1([Message]),
                             Pkg
                     end,
            {reply, {text, Packet}, Req, State#websocket_state{messages = Rest}, hibernate}
    end;
websocket_info({message_arrived, Pid}, Req, State = #websocket_state{
    pid = Pid, messages = RestMessages
}) ->
    Messages =  case socketio_session:safe_poll(Pid) of
                    {error, noproc} ->
                        [];
                    Result ->
                        Result
                end,
    RestMessages2 = lists:append([RestMessages, Messages]),
    self() ! go,
    {ok, Req, State#websocket_state{messages = RestMessages2}, hibernate};
websocket_info({timeout, _TRef, {?MODULE, Pid}}, Req, State = #websocket_state{
    config = #config{protocol = Protocol, heartbeat = HeartBeat}, pid = Pid, version = 0
}) ->
    socketio_session:refresh(Pid),
    erlang:start_timer(HeartBeat, self(), {?MODULE, Pid}),
    Packet = Protocol:encode(heartbeat),
    {reply, {text, Packet}, Req, State, hibernate};
websocket_info({'DOWN', _Ref, process, Pid, _Reason}, Req, State = #websocket_state{pid = Pid}) ->
    {shutdown, Req, State};
websocket_info(_Info, Req, State) ->
    {ok, Req, State, hibernate}.

enable_cors(Req) ->
    case cowboy_req:header(<<"origin">>, Req) of
        undefined ->
            Req;
        Origin ->
            Req1 = cowboy_req:set_resp_header(<<"access-control-allow-origin">>, Origin, Req),
            cowboy_req:set_resp_header(<<"access-control-allow-credentials">>, <<"true">>, Req1)
    end.

get_request_data(Req, JsonP) ->
    case JsonP of
        undefined ->
            case cowboy_req:body(Req) of
                {ok, Body, Req1} ->
                    {ok, Body, Req1};
                {error, _} ->
                    error
            end;
        _Num ->
            case cowboy_req:body_qs(Req) of
                {ok, PostVals, Req1} ->
                    Data = proplists:get_value(<<"d">>, PostVals),
                    Data2 = binary:replace(Data, <<"\\\n">>, <<"\n">>, [global]),
                    Data3 = binary:replace(Data2, <<"\\\\n">>, <<"\\n">>, [global]),
                    {ok, Data3, Req1};
                {error, _} ->
                    error
            end
    end.

encode_polling_xhr_packets_v1(PacketList) ->
    lists:foldl(fun(Packet, AccIn) ->
        PacketLen = [list_to_integer([D]) || D <- integer_to_list(byte_size(Packet))],
        PacketLenBin = list_to_binary(PacketLen),
        <<AccIn/binary, 0, PacketLenBin/binary, 255, Packet/binary>>
    end, <<>>, PacketList).

encode_polling_json_packets_v1(PacketList, JsonP) ->
    Payload = lists:foldl(fun(Packet, AccIn) ->
        ResultLenBin = integer_to_binary(byte_size(Packet)),
        Packet2 = escape_character(Packet, <<"\\">>),
        Packet3 = escape_character(Packet2, <<"\"">>),
        Packet4 = escape_character(Packet3, <<"\\n">>),
        <<AccIn/binary, ResultLenBin/binary, ":", Packet4/binary>>
    end, <<>>, PacketList),
    <<"___eio[", JsonP/binary, "](\"", Payload/binary, "\");">>.

escape_character(Data, CharBin) ->
    binary:replace(Data, CharBin, <<"\\", CharBin/binary>>, [global]).
