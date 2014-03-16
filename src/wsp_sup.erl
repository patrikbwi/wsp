-module(wsp_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(Options) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Options).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init(Options) ->
    Server = {wsp_server, {wsp_server, start_link, [Options]},
	      permanent, 5000, worker, [wsp_server]},
    {ok, { {one_for_one,3,5}, [Server]} }.


