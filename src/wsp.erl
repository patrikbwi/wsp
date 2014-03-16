%%% @author Patrik Winroth <patrik@bwi.se>
%%% @copyright (C) 2014, Patrik Winroth
%%% @doc
%%%    weather station reader
%%% @end

-module(wsp).

-export([start/0]).

start() ->
    application:start(wsp).

