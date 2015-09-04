engine.io-cowboy
================

### Overview

This project is an open-source Erlang implementation of an [Engine.IO](https://github.com/socketio/engine.io) server. Based on [sinnus/socket.io-cowboy](https://github.com/sinnus/socket.io-cowboy) and improvements thereto by [wuyingfengsui](https://github.com/wuyingfengsui/socket.io-cowboy) (including adding support for the v1 Socket.IO protocol),
this fork modifies its predecessors as follows:
   1. Supports only the Engine.IO protocol, not the Socket.IO protocol, although that would be easy to layer on top.
   2. Removes support for older Socket.IO protocol.
   3. Will add end-to-end tests using the reference implementation of the Engine.IO JavaScript client.

Licensed under the Apache License 2.0.

### Features

* Supports 1.5.0+ version of [Engine.IO client](https://github.com/socketio/engine.io-client)
* Supports polling(jsonp & xhr) transport
* Supports websocket transport
* Supports SSL

#Usage example

The example you can find in demo directory. Just make and execute start.sh script. Url to check: http://localhost:8080/index.html
