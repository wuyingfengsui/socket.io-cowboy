compile:
	./rebar compile

fixcowboy:
	# Temporary hack to work around brokenness in latest Cowboy...
	sed -i.bak "s/-spec init(pid(), ranch:ref(), inet:socket(), module(), opts(), module()) -> ok.//" deps/cowboy/src/cowboy_http2.erl

eunit:
	./rebar eunit
