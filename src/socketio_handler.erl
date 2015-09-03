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

-record(http_state, {action, config, sid, heartbeat_tref, messages, pid, jsonp, loop = false}).
-record(websocket_state, {config, pid, messages}).

init(Req, [Config]) ->
    Req2 = enable_cors(Req),
    KeyValues = cowboy_req:parse_qs(Req2),
    Sid = proplists:get_value(<<"sid">>, KeyValues),
    Transport = proplists:get_value(<<"transport">>, KeyValues),
    JsonP = proplists:get_value(<<"j">>, KeyValues),
    case {Transport, Sid} of
        {<<"polling">>, undefined} ->
            handle(Req2, #http_state{action = create_session, config = Config, jsonp = JsonP});
        {<<"polling">>, _} when is_binary(Sid) ->
            handle_polling(Req2, Sid, Config, JsonP);
        {<<"websocket">>, _} ->
            websocket_init(Req, Config);
        _ ->
            handle(Req2, #http_state{config = Config})
    end.

%% Http handlers
handle(Req, HttpState = #http_state{action = create_session, jsonp = JsonP, config = #config{
    heartbeat = HeartbeatInterval,
    heartbeat_timeout = HeartbeatTimeout,
    session_timeout = SessionTimeout,
    opts = Opts,
    callback = Callback
}}) ->
    Sid = uuids:new(),
    PeerAddress = cowboy_req:peer(Req),

    _Pid = socketio_session:create(Sid, SessionTimeout, Callback, Opts, PeerAddress),

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

    Req1 = cowboy_req:reply(200, HttpHeaders, <<Result2/binary>>, Req),
    {ok_or_stop(HttpState), Req1, HttpState};

handle(Req, HttpState = #http_state{action = data, messages = Messages, jsonp = JsonP}) ->
    {ok, Req1} = reply_messages(Req, Messages, false, JsonP),
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

handle(Req, HttpState = #http_state{action = ok}) ->
    Req1 = cowboy_req:reply(200, text_headers(), <<"ok">>, Req),
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

reply_messages(Req, Messages, SendNop, undefined) ->
    PacketList = case {SendNop, Messages} of
                 {true, []} ->
                     socketio_data_protocol:encode_v1([nop]);
                 _ ->
                     socketio_data_protocol:encode_v1(Messages)
             end,
    PacketListBin = encode_polling_xhr_packets_v1(PacketList),
    cowboy_req:reply(200, stream_headers(), PacketListBin, Req);

reply_messages(Req, Messages, SendNop, JsonP) ->
    PacketList = case {SendNop, Messages} of
                     {true, []} ->
                         socketio_data_protocol:encode_v1([nop]);
                     _ ->
                         socketio_data_protocol:encode_v1(Messages)
                 end,
    PacketListBin = encode_polling_json_packets_v1(PacketList, JsonP),
    cowboy_req:reply(200, javascript_headers(), PacketListBin, Req).

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

safe_poll(Req, HttpState = #http_state{jsonp = JsonP}, Pid, WaitIfEmpty) ->
    try
        Messages = socketio_session:poll(Pid),
        case {WaitIfEmpty, Messages} of
            {true, []} ->
                case socketio_session:transport(Pid) of
                    websocket ->
                        {ok, Req1} = reply_messages(Req, [], true, JsonP),
                        {ok, Req1, HttpState};
                    _ ->
                        % Always 'ok', never 'stop' for loop handler.
                        {ok, Req, HttpState}
                end;
            _ ->
                {ok, Req1} = reply_messages(Req, Messages, true, JsonP),
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

handle_polling(Req, Sid, Config, JsonP) ->
    Method = cowboy_req:method(Req),
    case {socketio_session:find(Sid), Method} of
        {{ok, Pid}, <<"GET">>} ->
            case socketio_session:pull_no_wait(Pid, self()) of
                {error, noproc} ->
                    {ok, cowboy_req:reply(400, <<"Can't upgrade">>, Req), #http_state{action = error, config = Config, sid = Sid, jsonp = JsonP}};
                session_in_use ->
                    {ok, cowboy_req:reply(400, <<"Can't upgrade">>, Req), #http_state{action = error, config = Config, sid = Sid, jsonp = JsonP}};
                [] ->
                    case socketio_session:transport(Pid) of
                        websocket ->
                            {ok, Req, #http_state{action = data, messages = [nop], config = Config, sid = Sid, pid = Pid, jsonp = JsonP}};
                        _ ->
                            {cowboy_loop, Req, #http_state{action = heartbeat, config = Config, sid = Sid, pid = Pid, jsonp = JsonP, loop = true}}
                    end;
                Messages ->
                    {ok, Req, #http_state{action = data, messages = Messages, config = Config, sid = Sid, pid = Pid, jsonp = JsonP}}
            end;
        {{ok, Pid}, <<"POST">>} ->
            case get_request_data(Req, JsonP) of
                {ok, Data2, Req2} ->
                    Messages = case catch(socketio_data_protocol:decode_v1(Data2)) of
                                   {'EXIT', _Reason} ->
                                       [];
                                   {error, _Reason} ->
                                       [];
                                   Msgs ->
                                       Msgs
                               end,
                    case socketio_session:recv(Pid, Messages) of
                        noproc ->
                            {ok, cowboy_req:reply(400, <<"Can't upgrade">>, Req2), #http_state{action = error, config = Config, sid = Sid, jsonp = JsonP}};
                        _ ->
                            {ok, Req2, #http_state{action = ok, config = Config, sid = Sid, jsonp = JsonP}}
                    end;
                error ->
                    {ok, cowboy_req:reply(400, <<"Can't upgrade">>, Req), #http_state{action = error, config = Config, sid = Sid}}
            end;
        {{error, not_found}, _} ->
            {ok, Req, #http_state{action = not_found, sid = Sid, config = Config, jsonp = JsonP}};
        _ ->
            {ok, Req, #http_state{action = error, sid = Sid, config = Config, jsonp = JsonP}}
    end.

%% Websocket handlers
websocket_init(Req, Config) ->
    KeyValues = cowboy_req:parse_qs(Req),
    case proplists:get_value(<<"sid">>, KeyValues, undefined) of
        Sid when is_binary(Sid) ->
            case socketio_session:find(Sid) of
                {ok, Pid} ->
                    erlang:monitor(process, Pid),
                    socketio_session:upgrade_transport(Pid, websocket),
                    {cowboy_websocket, Req, #websocket_state{config = Config, pid = Pid, messages = []}};
                {error, not_found} ->
                    {ok, cowboy_req:reply(500, <<"No such session">>, Req)}
            end;
        _ ->
            {ok, cowboy_req:reply(500, <<"No such session">>, Req)}
    end.

websocket_handle({text, Data}, Req, State = #websocket_state{ pid = Pid }) ->
    case catch (socketio_data_protocol:decode_v1_for_websocket(Data)) of
        {'EXIT', _Reason} ->
            {ok, Req, State};
        [{ping, Rest}] ->               %% only for socketio v1
            Packet = socketio_data_protocol:encode_v1({pong, Rest}),
            socketio_session:refresh(Pid),
            {reply, {text, Packet}, Req, State};
        [upgrade] ->                    %% only for socketio v1
            self() ! go,
            {ok, Req, State};
        Msgs ->
            case socketio_session:recv(Pid, Msgs) of
                noproc ->
                    {shutdown, Req, State};
                _ ->
                    {ok, Req, State}
            end
    end;
websocket_handle(_Data, Req, State) ->
    {ok, Req, State}.

websocket_info(go, Req, State = #websocket_state{pid = Pid, messages = RestMessages}) ->
    case socketio_session:pull(Pid, self()) of
        {error, noproc} ->
            {shutdown, Req, State};
        session_in_use ->
            {ok, Req, State};
        Messages ->
            RestMessages2 = lists:append([RestMessages, Messages]),
            self() ! go_rest,
            {ok, Req, State#websocket_state{messages = RestMessages2}}
    end;
websocket_info(go_rest, Req, State = #websocket_state{messages = RestMessages}) ->
    case RestMessages of
        [] ->
            {ok, Req, State};
        [Message | Rest] ->
            self() ! go_rest,

            [Packet] = socketio_data_protocol:encode_v1([Message]),
            {reply, {text, Packet}, Req, State#websocket_state{messages = Rest}}
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
    {ok, Req, State#websocket_state{messages = RestMessages2}};
websocket_info({'DOWN', _Ref, process, Pid, _Reason}, Req, State = #websocket_state{pid = Pid}) ->
    {shutdown, Req, State};
websocket_info(_Info, Req, State) ->
    {ok, Req, State}.

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
