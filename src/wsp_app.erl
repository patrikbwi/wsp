-module(tellstick_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    Options = case application:get_env(tellstick, options) of
		  undefined -> [];
		  {ok, O1} -> O1
	      end,
    tellstick_sup:start_link(Options).

stop(_State) ->
    ok.
