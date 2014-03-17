-module(wsp_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    Options = case application:get_env(wsp, options) of
		  undefined -> [];
		  {ok, O1} -> O1
	      end,
    wsp_sup:start_link(Options).

stop(_State) ->
    ok.
