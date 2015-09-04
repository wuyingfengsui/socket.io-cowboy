#!/bin/sh
pushd ..
make
popd
make
erl -name demo@127.0.0.1 -setcookie demo -pa ebin -pa ../ebin ../deps/*/ebin -eval "demo:start()."
