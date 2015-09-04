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
-module(engineio_handler).
-author('Kirill Trofimov <sinnus@gmail.com>').
-author('wuyingfengsui@gmail.com').
-author('Jói Sigurdsson <joi@crankwheel.com>').

-include("engineio_internal.hrl").

-export([init/2, terminate/3,
         info/3,
         websocket_handle/3, websocket_info/3]).

% TODO(joi): How do we get notified of session timeout (info timeout)?

-record(http_state, {config, sid, heartbeat_tref, pid, jsonp, dbgmethod, dbgurl}).
-record(websocket_state, {config, pid, messages}).

init(Req, [Config]) ->
    Req2 = enable_cors(Req),
    KeyValues = cowboy_req:parse_qs(Req2),
    Sid = proplists:get_value(<<"sid">>, KeyValues),
    Transport = proplists:get_value(<<"transport">>, KeyValues),
    JsonP = proplists:get_value(<<"j">>, KeyValues),
    case {Transport, Sid} of
        {<<"polling">>, undefined} ->
            create_session(Req2, #http_state{config = Config, jsonp = JsonP});
        {<<"polling">>, _} when is_binary(Sid) ->
            handle_polling(Req2, Sid, Config, JsonP);
        {<<"websocket">>, _} ->
            websocket_init(Req, Config);
        _ ->
            ?DBGPRINT({"404, unknown tranpsort", Transport, Sid}),
            {ok, cowboy_req:reply(404, [], <<>>, Req2), #http_state{}}
    end.

%% Http handlers
create_session(Req, HttpState = #http_state{jsonp = JsonP, config = #config{
    heartbeat = HeartbeatInterval,
    heartbeat_timeout = HeartbeatTimeout,
    session_timeout = SessionTimeout,
    opts = Opts,
    callback = Callback
}}) ->
    Sid = uuids:new(),
    PeerAddress = cowboy_req:peer(Req),

    _Pid = engineio_session:create(Sid, SessionTimeout, Callback, Opts, PeerAddress),

    Result = jiffy:encode({[
        {<<"sid">>, Sid},
        {<<"pingInterval">>, HeartbeatInterval}, {<<"pingTimeout">>, HeartbeatTimeout},
        {<<"upgrades">>, [<<"websocket">>]}
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
    {ok, Req1, HttpState}.

% Invariant in all of these: We are an HTTP loop handler.
info({timeout, TRef, {?MODULE, Pid}}, Req, HttpState = #http_state{heartbeat_tref = TRef}) ->
    safe_poll(Req, HttpState#http_state{heartbeat_tref = undefined}, Pid, false);
info({message_arrived, Pid}, Req, HttpState) ->
    safe_poll(Req, HttpState, Pid, true);
info(Info, Req, HttpState) ->
    % TODO(joi): Log the unexpected message.
    ?DBGPRINT(Info),
    {stop, Req, HttpState}.

% TODO(joi): We should perhapse end the session if we get Reason = {{error, closed}}.
terminate(_Reason, _Req, _HttpState = #http_state{heartbeat_tref = HeartbeatTRef, pid = Pid}) ->
    % Invariant: We are an HTTP handler (loop or regular).
    ?DBGPRINT({_Reason}),
    safe_unsub_caller(Pid, self()),
    case HeartbeatTRef of
        undefined ->
            ok;
        _ ->
            erlang:cancel_timer(HeartbeatTRef),
            ok
    end;
terminate(_Reason, _Req, #websocket_state{pid = Pid}) ->
    % Invariant: We are a WebSocket handler.
    engineio_session:disconnect(Pid),
    ok.

text_headers() -> [ {<<"Content-Type">>, <<"text/plain; charset=utf-8">>} ].

stream_headers() -> [ {<<"Content-Type">>, <<"application/octet-stream">>} ].

javascript_headers() ->
    [
        {<<"Content-Type">>, <<"text/javascript; charset=UTF-8">>},
        {<<"X-XSS-Protection">>, <<"0">>}
    ].

% If SendNop is true, we must send at least one message to flush our queue,
% so if the message queue is empty, we still send [nop].
reply_messages(Req, Messages, SendNop, undefined) ->
    PacketList = case {SendNop, Messages} of
        {true, []} ->
            engineio_data_protocol:encode_v1([nop]);
        _ ->
            engineio_data_protocol:encode_v1(Messages)
    end,
    PacketListBin = encode_polling_xhr_packets_v1(PacketList),
    cowboy_req:reply(200, stream_headers(), PacketListBin, Req);
reply_messages(Req, Messages, SendNop, JsonP) ->
    PacketList = case {SendNop, Messages} of
        {true, []} ->
            engineio_data_protocol:encode_v1([nop]);
        _ ->
            engineio_data_protocol:encode_v1(Messages)
    end,
    PacketListBin = encode_polling_json_packets_v1(PacketList, JsonP),
    cowboy_req:reply(200, javascript_headers(), PacketListBin, Req).

safe_unsub_caller(undefined, _Caller) ->
    ok;
safe_unsub_caller(_Pid, undefined) ->
    ok;
safe_unsub_caller(Pid, Caller) ->
    try
        engineio_session:unsub_caller(Pid, Caller),
        ok
    catch
        exit:{noproc, _} ->
            error
    end.

safe_poll(Req, HttpState = #http_state{jsonp = JsonP}, Pid, WaitIfEmpty) ->
    % INVARIANT: We are an HTTP loop handler.
    try
        Messages = engineio_session:poll(Pid),
        Transport = engineio_session:transport(Pid),
        case {Transport, WaitIfEmpty, Messages} of
            {websocket, _, _} ->
                % Our transport has been switched to websocket, so we flush
                % the transport, sending a nop if there are no messages in the
                % queue.
                {stop, reply_messages(Req, Messages, true, JsonP), HttpState};
            {_, true, []} ->
                % Not responding with 'stop' will make the loop handler continue
                % to wait.
                {ok, Req, HttpState};
            _ ->
                {stop, reply_messages(Req, Messages, true, JsonP), HttpState}
        end
    catch
        exit:{noproc, _} ->
            ?DBGPRINT({"Couldn't talk to PID", Pid, JsonP, WaitIfEmpty}),
            {stop, cowboy_req:reply(404, [], <<>>, Req), HttpState}
    end.

handle_polling(Req, Sid, Config, JsonP) ->
    Method = cowboy_req:method(Req),
    case {engineio_session:find(Sid), Method} of
        {{ok, Pid}, <<"GET">>} ->
            case engineio_session:pull_no_wait(Pid, self()) of
                {error, noproc} ->
                    ?DBGPRINT({"No such session", Pid}),
                    {ok, cowboy_req:reply(400, <<"No such session">>, Req), #http_state{config = Config, sid = Sid, jsonp = JsonP}};
                session_in_use ->
                    ?DBGPRINT({"Session in use", Pid}),
                    {ok, cowboy_req:reply(404, <<"Session in use">>, Req), #http_state{config = Config, sid = Sid, jsonp = JsonP}};
                [] ->
                    case engineio_session:transport(Pid) of
                        websocket ->
                            % Just send a NOP to flush this transport.
                            {ok, reply_messages(Req, [], true, JsonP), #http_state{config = Config, sid = Sid, pid = Pid, jsonp = JsonP}};
                        _ ->
                            TRef = erlang:start_timer(Config#config.heartbeat, self(), {?MODULE, Pid}),
                            {cowboy_loop, Req, #http_state{config = Config, sid = Sid, heartbeat_tref = TRef, pid = Pid, jsonp = JsonP, dbgmethod = Method, dbgurl = cowboy_req:path(Req)}}
                    end;
                Messages ->
                    Req1 = reply_messages(Req, Messages, false, JsonP),
                    {ok, Req1, #http_state{config = Config, sid = Sid, pid = Pid, jsonp = JsonP}}
            end;
        {{ok, Pid}, <<"POST">>} ->
            case get_request_data(Req, JsonP) of
                {ok, Data2, Req2} ->
                    Messages = case catch(engineio_data_protocol:decode_v1(Data2)) of
                                   {'EXIT', Reason} ->
                                       ?DBGPRINT({exit_decoding_messages, Reason}),
                                       [];
                                   {error, Reason} ->
                                       ?DBGPRINT({error_decoding_messages, Reason}),
                                       [];
                                   Msgs ->
                                       Msgs
                               end,
                    ?DBGPRINT({Data2, Messages}),
                    case engineio_session:recv(Pid, Messages) of
                        noproc ->
                            ?DBGPRINT({"Wrong sid", noproc, Pid, Messages}),
                            {ok, cowboy_req:reply(400, <<"Wrong sid">>, Req2), #http_state{config = Config, sid = Sid, jsonp = JsonP}};
                        _ ->
                            Req3 = cowboy_req:reply(200, text_headers(), <<"ok">>, Req2),
                            {ok, Req3, #http_state{config = Config, sid = Sid, jsonp = JsonP}}
                    end;
                error ->
                    ?DBGPRINT({"Can't get request data", Req, JsonP}),
                    {ok, cowboy_req:reply(400, <<"Error reading request data">>, Req), #http_state{config = Config, sid = Sid}}
            end;
        {{error, not_found}, _} ->
            ?DBGPRINT({"Can't find session", Sid, Method}),
            Req1 = cowboy_req:reply(404, [], <<"Not found">>, Req),
            {ok, Req1, #http_state{sid = Sid, config = Config, jsonp = JsonP}};
        _ ->
            ?DBGPRINT({"Unknown error", Sid, Method, Config, JsonP}),
            {ok, cowboy_req:reply(400, <<"Unknown error">>, Req), #http_state{sid = Sid, config = Config, jsonp = JsonP}}
    end.

%% Websocket handlers
websocket_init(Req, Config) ->
    KeyValues = cowboy_req:parse_qs(Req),
    case proplists:get_value(<<"sid">>, KeyValues, undefined) of
        Sid when is_binary(Sid) ->
            case engineio_session:find(Sid) of
                {ok, Pid} ->
                    erlang:monitor(process, Pid),
                    engineio_session:upgrade_transport(Pid, websocket),
                    {cowboy_websocket, Req, #websocket_state{config = Config, pid = Pid, messages = []}};
                {error, not_found} ->
                    ?DBGPRINT({"No such session", Sid}),
                    {ok, cowboy_req:reply(500, <<"No such session">>, Req)}
            end;
        UnexpectedResult ->
            ?DBGPRINT({"No SID provided", UnexpectedResult}),
            {ok, cowboy_req:reply(500, <<"No such session">>, Req)}
    end.

websocket_handle({text, Data}, Req, State = #websocket_state{ pid = Pid }) ->
    case catch (engineio_data_protocol:decode_v1_for_websocket(Data)) of
        {'EXIT', _Reason} ->
            {ok, Req, State};
        [{ping, Rest}] ->
            Packet = engineio_data_protocol:encode_v1({pong, Rest}),
            engineio_session:refresh(Pid),
            {reply, {text, Packet}, Req, State};
        [upgrade] ->
            self() ! go,
            {ok, Req, State};
        Msgs ->
            case engineio_session:recv(Pid, Msgs) of
                noproc ->
                    {shutdown, Req, State};
                _ ->
                    {ok, Req, State}
            end
    end;
websocket_handle(_Data, Req, State) ->
    % TODO(joi): Log
    {ok, Req, State}.

websocket_info(go, Req, State = #websocket_state{pid = Pid, messages = RestMessages}) ->
    case engineio_session:pull(Pid, self()) of
        {error, noproc} ->
            {shutdown, Req, State};
        session_in_use ->
            {ok, Req, State};  % TODO(joi): Really?
        Messages ->
            RestMessages2 = lists:append([RestMessages, Messages]),
            self() ! go_rest,
            {ok, Req, State#websocket_state{messages = RestMessages2}}
    end;
websocket_info(go_rest, Req, State = #websocket_state{messages = RestMessages}) ->
    case RestMessages of
        [] ->
            {ok, Req, State};
        _ ->
            Reply = [{text, engineio_data_protocol:encode_v1(M)} || M <- RestMessages],
            {reply, Reply, Req, State#websocket_state{messages = []}}
    end;
websocket_info({message_arrived, Pid}, Req, State = #websocket_state{pid = Pid, messages = RestMessages}) ->
    Messages =  case engineio_session:safe_poll(Pid) of
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
    % TODO(joi): Log
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
