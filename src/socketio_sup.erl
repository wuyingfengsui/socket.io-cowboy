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
-module(socketio_sup).
-author('Kirill Trofimov <sinnus@gmail.com>').
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SUPERVISOR, ?MODULE).

-spec start_link() -> {ok, Pid::pid()}.
start_link() ->
	supervisor:start_link({local, ?SUPERVISOR}, ?MODULE, []).

init([]) ->
	{ok, {{one_for_one, 10, 10},
          [
           {socketio_session_sup, {socketio_session_sup, start_link, []},
            permanent, 5000, supervisor, [socketio_session_sup]}
          ]}}.
