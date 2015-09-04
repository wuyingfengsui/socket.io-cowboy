-module(engineio_data_protocol).
-compile([{no_auto_import, [error/2]}]).
-include("engineio_internal.hrl").
-include_lib("eunit/include/eunit.hrl").

%% The source code was taken and modified from https://github.com/yrashk/socket.io-erlang/blob/master/src/socketio_data_v1.erl

% TODO(joi): Remove older protocol implementation (just keep _v1).

-export([encode/1,encode_v1/1,decode/1,decode_v1/1, decode_v1_for_websocket/1]).

-define(FRAME, 16#fffd).

encode([Message]) ->
    encode(Message);
encode(Messages) when is_list(Messages) ->
    lists:foldl(fun(Message, AccIn) ->
        Packet = encode(Message),
        LenBin = binary:list_to_bin(integer_to_list(binary_utf8_len(Packet))),
        <<AccIn/binary, ?FRAME/utf8, LenBin/binary, ?FRAME/utf8, Packet/binary>>
    end, <<>>, Messages);
encode({message, Id, EndPoint, Message}) ->
    message(Id, EndPoint, Message);
encode({json, Id, EndPoint, Message}) ->
    json(Id, EndPoint, Message);
encode({event, Id, EndPoint, EventName, EventArgs}) ->
    event(Id, EndPoint, EventName, EventArgs);
encode({ack, Id}) ->
    ack(Id);
encode({connect, Endpoint}) ->
    connect(Endpoint);
encode(heartbeat) ->
    heartbeat();
encode(nop) ->
    nop();
encode(disconnect) ->
    disconnect(<<>>).

encode_v1(Messages) when is_list(Messages) ->
    lists:map(fun(Message) ->
        encode_v1(Message)
    end, Messages);
encode_v1(disconnect) ->
    <<"41">>;
encode_v1({pong, Data}) ->
    <<"3", Data/binary>>;
encode_v1({message, Message}) ->
    <<"4", Message/binary>>;
encode_v1(nop) ->
    <<"6">>.

connect(<<>>) ->
    <<"1::">>;
connect(Endpoint) ->
    <<"1::", Endpoint/binary>>.

disconnect(<<>>) ->
    <<"0::">>;
disconnect(Endpoint) ->
    <<"0::", Endpoint/binary>>.

heartbeat() ->
    <<"2::">>.

nop() ->
    <<"8::">>.

message(Id, EndPoint, Msg) when is_integer(Id) ->
    IdBin = binary:list_to_bin(integer_to_list(Id)),
    <<"3:", IdBin/binary, ":", EndPoint/binary, ":", Msg/binary>>;
message(Id, EndPoint, Msg) when is_binary(Id) ->
    <<"3:", Id/binary, ":", EndPoint/binary, ":", Msg/binary>>.

json(Id, EndPoint, Msg) when is_integer(Id) ->
    IdBin = binary:list_to_bin(integer_to_list(Id)),
    case is_list(Msg) of
        true ->
            JsonBin = jiffy:encode({Msg});
        _ ->
            JsonBin = jiffy:encode(Msg)
    end,
    <<"4:", IdBin/binary, ":", EndPoint/binary, ":", JsonBin/binary>>;
json(Id, EndPoint, Msg) when is_binary(Id) ->
    case is_list(Msg) of
        true ->
            JsonBin = jiffy:encode({Msg});
        _ ->
            JsonBin = jiffy:encode(Msg)
    end,
    <<"4:", Id/binary, ":", EndPoint/binary, ":", JsonBin/binary>>.

event(Id, EndPoint, EventName, EventArgs) when is_list(EventArgs) ->
    IdBin = make_sure_binary(Id),
    EventNameBin = make_sure_binary(EventName),
    EventBin = jiffy:encode({[{<<"name">>, EventNameBin},{<<"args">>, [{EventArgs}]}]}),
    <<"5:", IdBin/binary, ":", EndPoint/binary, ":", EventBin/binary>>;
event(Id, EndPoint, EventName, undefined) ->
    IdBin = make_sure_binary(Id),
    EventNameBin = make_sure_binary(EventName),
    EventBin = jiffy:encode({[{<<"name">>, EventNameBin}]}),
    <<"5:", IdBin/binary, ":", EndPoint/binary, ":", EventBin/binary>>;
event(Id, EndPoint, EventName, EventArgs) ->
    event(Id, EndPoint, EventName, [EventArgs]).

ack(Id) when is_integer(Id) ->
    IdBin = integer_to_binary(Id),
    <<"6:::", IdBin/binary>>;
ack(Id) when is_list(Id) ->
    IdBin = list_to_binary(Id),
    <<"6:::", IdBin/binary>>;
ack(Id) when is_binary(Id) ->
    <<"6:::", Id/binary>>.

error(EndPoint, Reason) ->
    [<<"7::">>, EndPoint, $:, Reason].
error(EndPoint, Reason, Advice) ->
    [<<"7::">>, EndPoint, $:, Reason, $+, Advice].

binary_utf8_len(Binary) ->
    binary_utf8_len(Binary, 0).
binary_utf8_len(<<>>, Len) ->
    Len;
binary_utf8_len(<<_X/utf8, Binary/binary>>, Len) ->
    binary_utf8_len(Binary, Len+1).

binary_utf8_split(Binary, Len) ->
    binary_utf8_split(Binary, Len, <<>>).
binary_utf8_split(<<Binary/binary>>, 0, AccIn) ->
    {AccIn, Binary};
binary_utf8_split(<<>>, _, AccIn) ->
    {AccIn, <<>>};
binary_utf8_split(<<X/utf8, Binary/binary>>, Len, AccIn) ->
    binary_utf8_split(Binary, Len-1, <<AccIn/binary, X/utf8>>).

decode_frame_len(X) ->
    decode_frame_len(X, "").
decode_frame_len(<<?FRAME/utf8, Rest/binary>>, Acc) ->
    L = lists:reverse(Acc),
    {list_to_integer(L), Rest};
decode_frame_len(<<Num, Rest/binary>>, Acc) when Num-$0 >= 0, Num-$0 =< 9 ->
    decode_frame_len(Rest, [Num|Acc]).

decode_frame(<<>>, Packets) ->
    Packets;
decode_frame(<<?FRAME/utf8, Rest/binary>>, Packets) ->
    {Len, R1} =  decode_frame_len(Rest),
    {Msg, R2} = binary_utf8_split(R1, Len),
    Packet = decode_packet(Msg),
    decode_frame(R2, [Packet|Packets]).

%%% PARSING
decode(<<?FRAME/utf8, Rest/binary>>) ->
    Frames = decode_frame(<<?FRAME/utf8, Rest/binary>>, []),
    lists:reverse(Frames);

decode(Binary) ->
    [decode_packet(Binary)].

decode_v1_for_websocket(Packet) when is_binary(Packet) ->
    [decode_packet_v1(Packet)].
decode_v1(BodyBin) when is_binary(BodyBin) ->
    decode_v1(parse_polling_body_for_v1(BodyBin));
decode_v1(Packets) when is_list(Packets) ->
    lists:map(fun(Packet) ->
        decode_packet_v1(Packet)
    end, Packets).

decode_packet(<<"0">>) -> disconnect;
decode_packet(<<"0::", EndPoint/binary>>) -> {disconnect, EndPoint};
%% Incomplete, needs to handle queries
decode_packet(<<"1::", EndPoint/binary>>) -> {connect, EndPoint};
decode_packet(<<"2::", _Rest/binary>>) -> heartbeat;
decode_packet(<<"3:", Rest/binary>>) ->
    {Id, R1} = id(Rest),
    {EndPoint, Data} = endpoint(R1),
    {message, Id, EndPoint, Data};
decode_packet(<<"4:", Rest/binary>>) ->
    {Id, R1} = id(Rest),
    {EndPoint, Data} = endpoint(R1),
    Result = jiffy:decode(Data),
    case is_tuple(Result) of
        true ->
            {Result2} = Result,
            {json, Id, EndPoint, Result2};
        _ ->
            {json, Id, EndPoint, Result}
    end;
decode_packet(<<"5:", Rest/binary>>) ->
    {Id, R1} = id(Rest),
    {EndPoint, Data} = endpoint(R1),
    {DataList} = jiffy:decode(Data),
    EventName = proplists:get_value(<<"name">>, DataList),
    [{EventArgs}] = case proplists:get_value(<<"args">>, DataList) of
                        undefined ->
                            [{undefined}];
                        [] ->
                            [{undefined}];
                        {EventArgsList} ->
                            [{EventArgsList}];
                        EventArgsList ->
                            EventArgsList
                    end,
    {event, Id, EndPoint, EventName, EventArgs};
decode_packet(<<"6:::", Rest/binary>>) ->
    Id = binary_to_integer(Rest),
    {ack, Id};
decode_packet(<<"7::", Rest/binary>>) ->
    {EndPoint, R1} = endpoint(Rest),
    case reason(R1) of
        {Reason, Advice} ->
            {error, EndPoint, Reason, Advice};
        Reason ->
            {error, EndPoint, Reason}
    end.

decode_packet_v1(<<"1">>) -> disconnect;
decode_packet_v1(<<"2", Rest/binary>>) ->
    {ping, Rest};
decode_packet_v1(<<"4", Rest/binary>>) ->
    {message, Rest};
decode_packet_v1(<<"5">>) -> upgrade.

parse_polling_body_for_v1(Body) ->
    parse_polling_body_for_v1(Body, []).

parse_polling_body_for_v1(<<>>, Packets) ->
    Packets;
parse_polling_body_for_v1(Rest, Packets) ->
    [LengthBin, RestBin] = binary:split(Rest, <<":">>),
    Length = binary_to_integer(LengthBin),
    <<Packet:Length/binary, Rest2/binary>> = RestBin,
    parse_polling_body_for_v1(Rest2, [Packet | Packets]).

id(X) -> id(X, "").
id(<<$:, Rest/binary>>, "") ->
    {<<>>, Rest};
id(<<$:, Rest/binary>>, Acc) ->
    L = lists:reverse(Acc),
    {list_to_integer(L), Rest};
id(<<$+,$:, Rest/binary>>, Acc) when Acc =/= "" ->
    {lists:reverse([$+|Acc]), Rest};
id(<<Num, Rest/binary>>, Acc) when Num-$0 >= 0, Num-$0 =< 9 ->
    id(Rest, [Num|Acc]).

endpoint(X) -> endpoint(X, "").
endpoint(<<$:, Rest/binary>>, Acc) -> {binary:list_to_bin(lists:reverse(Acc)), Rest};
endpoint(<<X, Rest/binary>>, Acc) -> endpoint(Rest, [X|Acc]).

reason(X) ->
    case list_to_tuple(binary:split(X, <<"+">>)) of
        {E} -> E;
        T -> T
    end.

make_sure_binary(Data) ->
    if
        is_list(Data) ->
            list_to_binary(Data);
        is_integer(Data) ->
            integer_to_binary(Data);
        is_atom(Data) ->
            atom_to_binary(Data, latin1);
        true ->
            Data
    end.

%%% Tests based off the examples on the page
%%% ENCODING
disconnect_test_() ->
    [?_assertEqual(<<"0::/test">>, disconnect(<<"/test">>)),
        ?_assertEqual(<<"0::">>, disconnect(<<>>)),
        ?_assertEqual(<<"41">>, encode_v1(disconnect))].

connect_test_() -> []. % Only need to read, never to encode

%% No format specified in the spec.
heartbeat_test() ->
    [?_assertEqual(<<"2::">>, heartbeat()),
        ?_assertEqual(<<"3test">>, encode_v1({pong, <<"test">>}))].

message_test_() ->
    [?_assertEqual(<<"3:1::blabla">>, message(1, <<"">>, <<"blabla">>)),
        ?_assertEqual(<<"3:2::bla">>, message(2, <<"">>, <<"bla">>)),
        ?_assertEqual(<<"3:::bla">>, message(<<"">>, <<"">>, <<"bla">>)),
        ?_assertEqual(<<"3:4+:b:bla">>, message(<<"4+">>, <<"b">>, <<"bla">>)),
        ?_assertEqual(<<"3::/test:bla">>, message(<<"">>, <<"/test">>, <<"bla">>)),
        ?_assertEqual(<<"4test">>, encode_v1({message, <<"test">>}))].

json_test_() ->
    [?_assertEqual(<<"4:1::{\"a\":\"b\"}">>,
        json(1, <<"">>, [{<<"a">>,<<"b">>}])),
        %% No demo for this, but the specs specify it
        ?_assertEqual(<<"4:1:/test:{\"a\":\"b\"}">>,
            json(1, <<"/test">>, [{<<"a">>,<<"b">>}])),
        ?_assertEqual(<<"4:1+:/test:{\"a\":\"b\"}">>,
            json(<<"1+">>, <<"/test">>, [{<<"a">>,<<"b">>}])),
        ?_assertEqual(<<"4::/test:{\"a\":\"b\"}">>,
            json(<<"">>, <<"/test">>, [{<<"a">>,<<"b">>}]))].

error_test_() ->
    %% No example, liberal interpretation
    [?_assertEqual(<<"7::end:you+die">>,
        iolist_to_binary(error("end","you","die"))),
        ?_assertEqual(<<"7:::you">>, iolist_to_binary(error("","you")))].

%% DECODING TESTS
d_disconnect_test_() ->
    [?_assertEqual({disconnect, <<"/test">>}, decode_packet(<<"0::/test">>)),
        ?_assertEqual(disconnect, decode_packet(<<"0">>)),
        ?_assertEqual(disconnect, decode_packet_v1(<<"1">>))].

d_connect_test_() ->
    [].

%%% No format specified in the spec.
d_heartbeat_test() ->
    [?_assertEqual(heartbeat, decode_packet(heartbeat())),
        ?_assertEqual({ping, <<"test">>}, decode_packet_v1(<<"2test">>))].

d_message_test_() ->
    [?_assertEqual({message, 1, <<>>, <<"blabla">>}, decode_packet(message(1, <<"">>, <<"blabla">>))),
        ?_assertEqual({message, 2, <<>>, <<"bla">>}, decode_packet(message(2, <<"">>, <<"bla">>))),
        ?_assertEqual({message, <<"">>, <<>>, <<"bla">>}, decode_packet(message(<<"">>, <<"">>, <<"bla">>))),
        ?_assertEqual({message, "4+", <<"b">>, <<"bla">>}, decode_packet(message(<<"4+">>, <<"b">>, <<"bla">>))),
        ?_assertEqual({message, <<"">>, <<"/test">>, <<"bla">>}, decode_packet(message(<<"">>, <<"/test">>, <<"bla">>)))].

d_json_test_() ->
    [?_assertEqual({json, 1, <<>>, [{<<"a">>,<<"b">>}]},
        decode_packet(json(1, <<"">>, [{<<"a">>,<<"b">>}]))),
        ?_assertEqual({json, 1, <<"/test">>, [{<<"a">>,<<"b">>}]},
            decode_packet(json(1, <<"/test">>, [{<<"a">>,<<"b">>}]))),
        ?_assertEqual({json, "1+", <<"/test">>, [{<<"a">>,<<"b">>}]},
            decode_packet(json(<<"1+">>, <<"/test">>, [{<<"a">>,<<"b">>}]))),
        ?_assertEqual({json, <<"">>, <<"/test">>, [{<<"a">>,<<"b">>}]},
            decode_packet(json(<<"">>, <<"/test">>, [{<<"a">>,<<"b">>}])))].

d_error_test_() ->
    %% No example, liberal interpretation
    [?_assertEqual({error, <<"end">>, <<"you">>, <<"die">>},
        decode_packet(iolist_to_binary(error("end","you","die")))),
        ?_assertEqual({error, <<"">>, <<"you">>}, decode_packet(iolist_to_binary(error("","you"))))].

binary_utf8_split1_test_() ->
    A = <<"Привет">>,
    {A1, A2} = binary_utf8_split(A, 2),
    [?_assertEqual(A1, <<"Пр">>),
        ?_assertEqual(A2, <<"ивет">>)].

binary_utf8_split2_test_() ->
    A = <<"Hello world">>,
    {A1, A2} = binary_utf8_split(A, 5),
    B = <<>>,
    {B1, B2} = binary_utf8_split(B, 2),
    C = <<"ZZZ">>,
    {C1, C2} = binary_utf8_split(C, 200),
    D = <<"Z">>,
    {D1, D2} = binary_utf8_split(D, 1),
    [
        ?_assertEqual(<<"Hello">>, A1),
        ?_assertEqual(<<" world">>, A2),
        ?_assertEqual(<<>>, B1),
        ?_assertEqual(<<>>, B2),
        ?_assertEqual(<<"ZZZ">>, C1),
        ?_assertEqual(<<>>, C2),
        ?_assertEqual(<<"Z">>, D1),
        ?_assertEqual(<<>>, D2)
    ].

id_test_() ->
    [
        ?_assertEqual({12, <<"rest">>}, id(<<"12:rest">>)),
        ?_assertEqual({<<>>, <<"rest">>}, id(<<":rest">>))
    ].

decode_frame_test_() ->
    [
        ?_assertEqual([{message, 1, <<>>, <<"blabla">>}], decode(<<?FRAME/utf8, "12", ?FRAME/utf8, "3:1::blabla">>)),
        ?_assertEqual([{json, 1, <<>>, [{<<"a">>, <<"b">>}]},
            {message, 1, <<>>, <<"blabla">>}],
            decode(<<?FRAME/utf8, "14", ?FRAME/utf8, "4:1::{\"a\":\"b\"}",
            ?FRAME/utf8, "12", ?FRAME/utf8, "3:1::blabla">>))
    ].

encode_frame_test_() ->
    [
        ?_assertEqual(<<"3:::Привет">>, encode([{message, <<>>, <<>>, <<"Привет">>}])),
        ?_assertEqual(<<?FRAME/utf8, "10", ?FRAME/utf8, "3:::Привет",
        ?FRAME/utf8, "8", ?FRAME/utf8, "4:::\"ZX\"">>,
            encode([{message, <<>>, <<>>, <<"Привет">>},
                {json, <<>>, <<>>, <<"ZX">>}]))
    ].

decode_v1_regression_test_() ->
    [
        ?_assertEqual([{message, <<"{\"userName\":\"user485\",\"message\":\"styx\"}">>}],
                      decode_v1(<<"40:4{\"userName\":\"user485\",\"message\":\"styx\"}">>))
    ].

encode_v1_regression_test_() ->
    [
        ?_assertEqual([<<"4{\"userName\":\"user847\",\"message\":\"hello\"}">>],
                      encode_v1([{message,<<"{\"userName\":\"user847\",\"message\":\"hello\"}">>}]))
    ].
