socket.io-cowboy
================

### Overview

This project is an open-source Erlang implementation of [Socket.IO](http://socket.io/) server. Based on the [sinnus/socket.io-cowboy](https://github.com/sinnus/socket.io-cowboy) and improvements by [wuyingfengsui](https://github.com/wuyingfengsui/socket.io-cowboy). In particular wuyingfengsui had switched from ETS to Mnesia, had switched to Jiffy, and handles dead session processes correctly, all of which are desirable changes.

This fork will switch to Cowboy 2.0.

Licensed under the Apache License 2.0.

### Features

* Supports 0.7+ version of [Socket.IO-client](https://github.com/Automattic/socket.io-client) up to latest - 1.3.5
* Supports polling(jsonp & xhr) transport
* Supports websocket transport
* Supports SSL

#Usage example

The example you can find in demo directory. Just make and execute start.sh script. Url to check:

Socket.IO V0.x is [here](http://localhost:8080/index.html)

Socket.IO V1.x is [here](http://localhost:8080/index_v1.html)
