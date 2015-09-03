#!/bin/sh
erl -name demo@127.0.0.1 -setcookie demo -pa ebin -pa ../ebin ../deps/*/ebin -eval "enginedemo:start()."
