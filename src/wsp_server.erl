%%%-------------------------------------------------------------------
%%% @author Patrik Winroth <patrik@bwi.se>
%%% @copyright (C) 2014, Patrik Winroth
%%% @doc
%%%     wsp driver for weather station http://code.google.com/p/weatherpoller/.
%%% @end
%%%-------------------------------------------------------------------
-module(wsp_server).

-behaviour(gen_server).

-include_lib("lager/include/log.hrl").

%% API
-export([start_link/1, 
	 stop/0,
	 subscribe/0,
	 subscribe/1,
	 unsubscribe/1
        ]).

%% gen_server callbacks
-export([init/1, 
	 handle_call/3, 
	 handle_cast/2, 
	 handle_info/2,
	 terminate/2, 
	 code_change/3]).

%% Testing
-export([version/0,
	 setopt/1]).

-define(SERVER, ?MODULE). 

-record(subscription,
	{
	  pid,
	  mon,
	  pattern
	}).

-record(ctx, 
	{
	  handle,         %% serial port / net socket / undefined
	  device,         %% device string (for net = code )
	  variant,        %% stick/duo/net  stick|duo|net|simulated
	  version,        %% first version if detected
	  command,        %% last command
	  client,         %% last client
	  queue,          %% request queue
	  reply_timer,    %% timeout waiting for reply
	  reopen_ival,    %% interval betweem open retry 
	  reopen_timer,   %% timer ref
	  subs = []      %% #subscription{}
	}).

%% For dialyzer
-type start_options()::{device, Device::string()} |
		       {retry_timeout, TimeOut::timeout()}.

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server.
%%
%% Device contains the path to the Device and the version. <br/>
%% Timeout =/= 0 means that if the driver fails to open the device it
%% will try again in Timeout seconds.<br/>
%%
%% @end
%%--------------------------------------------------------------------
-spec start_link(list(Options::start_options())) -> 
		   {ok, Pid::pid()} | 
		   ignore | 
		   {error, Error::term()}.

start_link(Opts) ->
    lager:info("~p: start_link: args = ~p\n", [?MODULE, Opts]),
    gen_server:start_link({local,?SERVER}, ?MODULE, Opts, []).

%%--------------------------------------------------------------------
%% @doc
%% Stops the server.
%%
%% @end
%%--------------------------------------------------------------------
-spec stop() -> ok | {error, Error::term()}.

stop() ->
    gen_server:call(?SERVER, stop).

%%--------------------------------------------------------------------
%% @doc
%% Subscribe to wsp events.
%%
%% @end
%%--------------------------------------------------------------------
-spec subscribe() -> {ok,reference()} | {error, Error::term()}.
subscribe() ->
    subscribe([]).

-spec subscribe(Pattern::[{atom(),string()}]) ->
		       {ok,reference()} | {error, Error::term()}.
subscribe(Pattern) ->
    gen_server:call(?SERVER, {subscribe,self(),Pattern}).

%%--------------------------------------------------------------------
%% @doc
%% Unsubscribe from wsp events.
%%
%% @end
%%--------------------------------------------------------------------
-spec unsubscribe(Ref::reference()) -> ok | {error, Error::term()}.
unsubscribe(Ref) ->
    gen_server:call(?SERVER, {unsubscribe,Ref}).

version() ->
    gen_server:call(?SERVER, version).

%% @private
setopt(O={_Option, _Value}) ->
    gen_server:cast(?SERVER, {setopt, O}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
%%--------------------------------------------------------------------
%% @doc
%% Initializes the server
%%
%% @end
%%--------------------------------------------------------------------
-spec init(list(Options::start_options())) -> 
		  {ok, Ctx::#ctx{}} |
		  {ok, Ctx::#ctx{}, Timeout::timeout()} |
		  ignore |
		  {stop, Reason::term()}.

init(Opts) ->
    lager:info("~p: init: args = ~p,\n pid = ~p", [?MODULE, Opts, self()]),
    Device  = proplists:get_value(device, Opts, ""),
    Reopen_ival = proplists:get_value(retry_timeout, Opts, infinity),
    S = #ctx { device = Device, 
	       reopen_ival = Reopen_ival,
	       queue = queue:new()},
    case open(S) of
	{ok, S1} -> {ok, S1};
	Error -> {stop, Error}
    end.

open(Ctx=#ctx {device = DeviceName, variant=Variant,
	       reopen_ival = Reopen_ival }) ->

    %% FIXME: speed and options for Weatherstation
    Speed = 9600,
    Options = [{baud,Speed},{mode,list},{active,true},{packet,line},
	       {csize,8},{parity,none},{stopb,1}],
    case uart:open(DeviceName,Options) of
	{ok,U} ->
	    lager:debug("wsp open: ~s@~w -> ~p", [DeviceName,Speed,U]),
%%	    uart:send(U, "V+"), %% answer is picked in handle_info
	    {ok, Ctx#ctx { handle=U }};
	{error, E} when E =:= eaccess;
			E =:= enoent ->
	    if Reopen_ival =:= infinity ->
		    lager:debug("open: Driver not started, reason = ~p.", [E]),
		    {error, E};
	       true ->
		    lager:debug("open: uart could not be opened, will try again"
				" in ~p millisecs.", [Reopen_ival]),
		    Reopen_timer = erlang:start_timer(Reopen_ival,
						      self(), reopen),
		    {ok, Ctx#ctx { reopen_timer = Reopen_timer }}
	    end;
	Error ->
	    lager:debug("open: Driver not started, reason = ~p.", 
		 [Error]),
	    Error
    end.

close(Ctx=#ctx {handle = U}) when is_port(U) ->
    lager:debug("wsp ~w close", [U]),
    uart:close(U),
    {ok, Ctx#ctx { handle=undefined }};
close(Ctx) ->
    {ok, Ctx}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------

-type call_request()::
        stop.

-spec handle_call(Request::call_request(), From::{pid(), Tag::term()}, Ctx::#ctx{}) ->
			 {reply, Reply::term(), Ctx::#ctx{}} |
			 {noreply, Ctx::#ctx{}} |
			 {stop, Reason::atom(), Reply::term(), Ctx::#ctx{}}.

handle_call({subscribe,Pid,Pattern},_From,Ctx=#ctx{ subs=Subs}) ->
    Mon = erlang:monitor(process, Pid),
    Subs1 = [#subscription { pid = Pid, mon = Mon, pattern = Pattern}|Subs],
    {reply, {ok,Mon}, Ctx#ctx { subs = Subs1}};

handle_call({unsubscribe,Ref},_From,Ctx) ->
    erlang:demonitor(Ref),
    Ctx1 = remove_subscription(Ref,Ctx),
    {reply, ok, Ctx1};
handle_call(version, _From, Ctx) ->
    if Ctx#ctx.handle =:= undefined ->
	    {reply, {error,no_port}, Ctx};
       true ->
	    {reply, Ctx#ctx.version, Ctx}
    end;
handle_call(stop, _From, Ctx) ->
    {stop, normal, ok, Ctx}.

handle_call_(_Request, _From, Ctx) ->
    {reply, {error,bad_call}, Ctx}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(Msg::term(), Ctx::#ctx{}) -> 
			 {noreply, Ctx::#ctx{}} |
			 {stop, Reason::term(), Ctx::#ctx{}}.

handle_cast({setopt, {Option, Value}}, Ctx=#ctx { handle = U}) ->
    lager:debug("handle_cast: setopt ~p = ~p", [Option, Value]),
    uart:setopt(U, Option, Value),
    {noreply, Ctx};
handle_cast(Cast, Ctx=#ctx { handle = U, client=Client})
  when U =/= undefined, Client =/= undefined ->
    lager:debug("handle_cast: Driver busy, store cast ~p", [Cast]),
    Q = queue:in({cast,Cast}, Ctx#ctx.queue),
    {noreply, Ctx#ctx { queue = Q }};
handle_cast({command, Command}, Ctx=#ctx { handle = Handle}) ->
    if Ctx#ctx.variant =:= stick; Ctx#ctx.variant =:= duo ->
	    lager:debug("handle_cast: command ~p", [Command]),
	    _Reply = uart:send(Handle, Command),
	    lager:debug("handle_cast: command reply ~p", [_Reply]),
	    {noreply, Ctx};
       true ->
	    {noreply, Ctx}
    end;
handle_cast(_Msg, Ctx) ->
    lager:debug("handle_cast: Unknown message ~p", [_Msg]),
    {noreply, Ctx}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @end
%%--------------------------------------------------------------------
-type info()::
	{uart, U::port(), Data::binary()} |
	{uart_error, U::port(), Reason::term()} |
	{uart_closed, U::port()} |
	{timeout, reference(), reply} |
	{timeout, reference(), reopen} |
	{'DOWN',Ref::reference(),process,pid(),Reason::term()}.

-spec handle_info(Info::info(), Ctx::#ctx{}) -> 
			 {noreply, Ctx::#ctx{}} |
			 {stop, Reason::term(), Ctx::#ctx{}}.


handle_info({uart,U,Data},  Ctx) when U =:= Ctx#ctx.handle ->
    lager:debug("handle_info: port data ~p", [Data]),
    case trim(Data) of
	[$+,CmdChar|_CmdReply] when Ctx#ctx.client =/= undefined, 
				   CmdChar =:= hd(Ctx#ctx.command) ->
	    erlang:cancel_timer(Ctx#ctx.reply_timer),
	    gen_server:reply(Ctx#ctx.client, ok),
	    Ctx1 = Ctx#ctx { client=undefined, reply_timer=undefined,
			     command = "" },
	    next_command(Ctx1);
	[$+,$V|Vsn] -> 
	    {noreply, Ctx#ctx { version = Vsn }};
	[$+,$W|EventData] ->
	    Ctx1 = event_notify(EventData, Ctx),
	    {noreply, Ctx1};
	_ ->
	    lager:debug("handle_info: reply ~p", [Data]),
	    {noreply, Ctx}
    end;
handle_info({uart_error,U,Reason}, Ctx) when U =:= Ctx#ctx.handle ->
    if Reason =:= enxio ->
	    lager:error("uart error ~p device ~s unplugged?", 
			[Reason,Ctx#ctx.device]);
       true ->
	    lager:error("uart error ~p for device ~s", 
			[Reason,Ctx#ctx.device])
    end,
    {noreply, Ctx};
handle_info({uart_closed,U}, Ctx) when U =:= Ctx#ctx.handle ->
    uart:close(U),
    lager:error("uart close device ~s will retry", [Ctx#ctx.device]),
    case open(Ctx#ctx { handle=undefined}) of
	{ok, Ctx1} -> {noreply, Ctx1};
	Error -> {stop, Error, Ctx}
    end;

handle_info({timeout,TRef,reply}, Ctx=#ctx {reply_timer=TRef}) ->
    lager:debug("handle_info: timeout waiting for port", []),
    gen_server:reply(Ctx#ctx.client, {error, port_timeout}),
    Ctx1 = Ctx#ctx { reply_timer=undefined, client = undefined},
    next_command(Ctx1);

handle_info({timeout,Ref,reopen}, Ctx) when Ctx#ctx.reopen_timer =:= Ref ->
    case open(Ctx#ctx { handle=undefined, reopen_timer=undefined}) of
	{ok, Ctx1} -> {noreply, Ctx1};
	Error -> {stop, Error, Ctx}
    end;

handle_info({'DOWN',Ref,process,_Pid,_Reason},Ctx) ->
    lager:debug("handle_info: subscriber ~p terminated: ~p", 
	 [_Pid, _Reason]),
    Ctx1 = remove_subscription(Ref,Ctx),
    {noreply, Ctx1};
handle_info(_Info, Ctx) ->
    lager:debug("handle_info: Unknown info ~p", [_Info]),
    {noreply, Ctx}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason::term(), Ctx::#ctx{}) -> 
		       ok.

terminate(_Reason, Ctx) ->
    close(Ctx),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process ctx when code is changed
%%
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn::term(), Ctx::#ctx{}, Extra::term()) -> 
			 {ok, NewCtx::#ctx{}}.

code_change(_OldVsn, Ctx, _Extra) ->
    {ok, Ctx}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

next_command(Ctx) ->
    case queue:out(Ctx#ctx.queue) of
	{{value,{call,Call,From}}, Q1} ->
	    case handle_call_(Call, From, Ctx#ctx { queue=Q1}) of
		{reply,Reply,Ctx1} ->
		    gen_server:reply(From,Reply),
		    {noreply,Ctx1};
		CallResult ->
		    CallResult
	    end;
	{{value,{cast,Cast}}, Q1} ->
	    handle_cast(Cast, Ctx#ctx { queue=Q1});
	{empty, Q1} ->
	    {noreply, Ctx#ctx { queue=Q1}}
    end.
	    
trim([0|Cs])   -> trim(Cs);  %% check this, sometimes 0's occure in the stream
trim([$\s|Cs]) -> trim(Cs);
trim([$\t|Cs]) -> trim(Cs);
trim(Cs) -> trim_end(Cs).

trim_end([$\r,$\n]) -> [];
trim_end([$\n]) -> [];
trim_end([$\r]) -> [];
trim_end([]) -> [];
trim_end([C|Cs]) -> [C|trim_end(Cs)].

remove_subscription(Ref, Ctx=#ctx { subs=Subs}) ->
    Subs1 = lists:keydelete(Ref, #subscription.mon, Subs),
    Ctx#ctx { subs = Subs1 }.
    

event_notify(String, Ctx) ->
    Event = 
	[ case string:tokens(D, ":") of
	      ["data",Data="0x"++Value] ->
		  try erlang:list_to_integer(Value,16) of
		      V -> {data, V}
		  catch
		      error:Error ->  
		          lager:error("unable to convert ~p to integer:~p\n",
                                      [Data, Error]),
			  {data,Data}
		  end;
	      [K,V] ->
		  {list_to_atom(K), V};
	      [K] ->

	          {undefined, K}
	  end || D <- string:tokens(String, ";")],
    send_event(Ctx#ctx.subs, Event),
    %% send to event listener(s)
    %% io:format("Event: ~p\n", [Event]),
    Ctx.

send_event([#subscription{pid=Pid,mon=Ref,pattern=Pattern}|Tail], Event) ->
    case match_event(Pattern, Event) of
	true -> Pid ! {tellstick_event,Ref,Event};
	false -> false
    end,
    send_event(Tail,Event);
send_event([],_Event) ->
    ok.

match_event([], _) -> true;
match_event([{Key,ValuePat}|Kvs],Event) ->
    case lists:keyfind(Key, 1, Event) of
	{Key,ValuePat} -> match_event(Kvs, Event);
	_ -> false
    end.

