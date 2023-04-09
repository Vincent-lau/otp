-module(mnesia_causal).

-export([start/0, get_ts/0, send_msg/0, rcv_msg/3, rcv_msg/4, compare_vclock/2,
         deliver_one/1, tcstable/1]).
-export([init/1, handle_call/3, handle_cast/2]).
-export([get_buffered/0, get_mrd/0, new_clock/0, bot/0, is_bot/1, reset_with_nodes/1,
         register_stabiliser/1]).

-include("mnesia.hrl").

-import(mnesia_lib, [important/2, dbg_out/2, verbose/2, warning/2]).

-behaviour(gen_server).

-type ord() :: lt | eq | gt | cc.
-type lc() :: integer().
-type vclock() :: #{node() => lc()}.
-type msg() :: #commit{}.

-record(state,
        {send_seq :: integer(),
         delivered :: vclock(),
         buffer :: [mmsg()],
         mrd :: #{node() => vclock()},
         stable_ts :: vclock(),
         stabiliser_pid :: pid()}).
-record(mmsg, {tid :: pid(), tab :: mnesia:table(), msg :: msg(), from :: pid()}).

-type mmsg() :: #mmsg{}.
-type state() :: #state{}.

%% Helper

-spec bot() -> vclock().
bot() ->
    #{}.

-spec is_bot(vclock()) -> boolean().
is_bot(Ts) when is_map(Ts) andalso map_size(Ts) == 0 ->
    true;
is_bot(Ts) when is_map(Ts) ->
    false;
is_bot(_) ->
    error({badarg, bot}).

%% public API

start() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], []).

-spec get_ts() -> vclock().
get_ts() ->
    gen_server:call(?MODULE, get_ts).

-spec send_msg() -> {node(), vclock()}.
send_msg() ->
    gen_server:call(?MODULE, send_msg).

-spec get_buffered() -> [mmsg()].
get_buffered() ->
    gen_server:call(?MODULE, get_buf).

-spec get_mrd() -> #{node() => vclock()}.
get_mrd() ->
    gen_server:call(?MODULE, get_mrd).

%% @doc receive an event from another node
%% @return {vclock(), [event()]} the new vector clock and events ready to
%% be delivered
%% @end
-spec rcv_msg(pid(), #commit{}, mnesia:table()) -> [{pid(), #commit{}, mnesia:table()}].
rcv_msg(Tid, Commit, Tab) ->
    MMsgs =
        gen_server:call(?MODULE,
                        {receive_msg,
                         #mmsg{tid = Tid,
                               msg = Commit,
                               tab = Tab}}),
    lists:map(fun(#mmsg{tid = Tid2,
                        msg = Msg2,
                        tab = Tab2}) ->
                 {Tid2, Msg2, Tab2}
              end,
              MMsgs).

-spec rcv_msg(pid(), #commit{}, mnesia:table(), pid()) ->
                 [{pid(), #commit{}, mnesia:table(), pid()}].
rcv_msg(Tid, Commit, Tab, From) ->
    MMsgs =
        gen_server:call(?MODULE,
                        {receive_msg,
                         #mmsg{tid = Tid,
                               msg = Commit,
                               tab = Tab,
                               from = From}}),
    lists:map(fun(#mmsg{tid = Tid2,
                        msg = Msg2,
                        tab = Tab2,
                        from = From2}) ->
                 {Tid2, Msg2, Tab2, From2}
              end,
              MMsgs).

-spec deliver_one(#commit{}) -> ok.
deliver_one(#commit{sender = Sender, ts = Ts}) ->
    gen_server:call(?MODULE, {deliver_one, Sender, Ts}).

-spec tcstable(vclock()) -> boolean().
tcstable(Ts) ->
    gen_server:call(?MODULE, {tcstable, Ts}).

-spec register_stabiliser(pid()) -> ok.
register_stabiliser(ReceiverPid) ->
    gen_server:cast(?MODULE, {register_stabiliser, ReceiverPid}).

reset_with_nodes(Nodes) ->
    gen_server:call(?MODULE, {reset, Nodes}).

%% ====================gen_server callbacks====================
init([Nodes]) ->
    {ok,
     #state{send_seq = 0,
            delivered = new_clock(Nodes),
            buffer = [],
            mrd = new_mrds(Nodes),
            stable_ts = bot()}};
init(_Args) ->
    {ok,
     #state{send_seq = 0,
            delivered = new_clock(),
            buffer = [],
            mrd = new_mrds(),
            stable_ts = bot()}}.

handle_call(send_msg, _From, State = #state{delivered = Delivered, send_seq = SendSeq}) ->
    Deps = Delivered#{node() := SendSeq + 1},
    {reply, {node(), Deps}, State#state{send_seq = SendSeq + 1}};
handle_call({deliver_one, Sender, Ts},
            _From,
            State = #state{delivered = Delivered, mrd = MRD}) ->
    NewDelivered = increment(Sender, Delivered),
    MRD2 = update_mrd(MRD, Sender, Ts),
    StableTs = send_stable_ts(State#state{mrd = MRD2}),
    {reply,
     ok,
     State#state{delivered = NewDelivered,
                 mrd = MRD2,
                 stable_ts = StableTs}};
handle_call({receive_msg, MM = #mmsg{}}, _From, State = #state{}) ->
    {NewState, Deliverable} = find_deliverable(MM, State),
    {reply, Deliverable, NewState};
handle_call({tcstable, Ts}, _From, State = #state{mrd = MRD}) ->
    case Ts of
        #{} when map_size(Ts) == 0 ->
            {reply, true, State};
        Other when is_map(Other) ->
            Res = lists:all(fun(VClock) -> vclock_leq(Ts, VClock) end, maps:values(MRD)),
            dbg_out("tcstable: ~p ~p ~p ~n", [Res, Ts, MRD]),
            {reply, Res, State}
    end;
handle_call(get_buf, _From, #state{buffer = Buffer} = State) ->
    {reply, Buffer, State};
handle_call(get_ts, _From, #state{delivered = D} = State) ->
    {reply, D, State};
handle_call(get_mrd, _From, #state{mrd = MRD} = State) ->
    {reply, MRD, State};
handle_call({reset, Nodes}, _From, #state{stabiliser_pid = StabiliserPid}) ->
    {ok, NewState} = init([Nodes]),
    {reply, ok, NewState#state{stabiliser_pid = StabiliserPid}}.

handle_cast({register_stabiliser, ReceiverPid}, State) ->
    {noreply, State#state{stabiliser_pid = ReceiverPid, stable_ts = bot()}}.

%%% internal functions

%% @doc
%% update the delivered vector clock and buffer
%% @returns {list(), [event()]} the new buffer and events ready to be delivered
%% where we guarantee that if the input message is deliverable then it is at the
%% tail of the list
%% @end
-spec find_deliverable(mmsg(), state()) -> {vclock(), [mmsg()], [mmsg()]}.
find_deliverable(MM = #mmsg{msg = #commit{ts = Deps, sender = Sender}},
                 State =
                     #state{delivered = Delivered,
                            buffer = Buffer,
                            mrd = MRD}) ->
    case msg_deliverable(Deps, Delivered, Sender) of
        true ->
            dbg_out("input message ~p deliverable~n", [MM]),
            NewDelivered = increment(Sender, Delivered),
            MRD2 = update_mrd(MRD, Sender, Deps),
            StableTs = send_stable_ts(State#state{mrd = MRD2}),
            do_find_deliverable(State#state{delivered = NewDelivered,
                                            buffer = Buffer,
                                            mrd = MRD2,
                                            stable_ts = StableTs},
                                [MM]);
        false ->
            dbg_out("input message ~p not deliverable~n", [MM]),
            {State, []}
    end.

-spec do_find_deliverable(state(), [mmsg()]) -> {state(), [mmsg()]}.
do_find_deliverable(State = #state{delivered = Delivered, buffer = Buff}, Deliverable) ->
    {Dev, NDev} =
        lists:partition(fun(#mmsg{msg = #commit{ts = Deps, sender = Sender}}) ->
                           msg_deliverable(Deps, Delivered, Sender)
                        end,
                        Buff),
    case Dev of
        [] ->
            {State, Deliverable};
        Dev when length(Dev) > 0 ->
            State2 =
                lists:foldl(fun(#mmsg{msg = #commit{sender = Sender, ts = Ts}}, StateIn) ->
                               Dev2 = increment(Sender, StateIn#state.delivered),
                               MRD2 = update_mrd(StateIn#state.mrd, Sender, Ts),
                               StateOut = StateIn#state{delivered = Dev2, mrd = MRD2},
                               StableTs2 = send_stable_ts(StateOut),
                               StateOut#state{stable_ts = StableTs2}
                            end,
                            State,
                            Dev),
            do_find_deliverable(State2#state{buffer = NDev}, Dev ++ Deliverable)
    end.

-spec update_mrd(#{node() => vclock()}, node(), vclock()) -> #{node() => vclock()}.
update_mrd(MRD, Sender, Ts) ->
    NewTs = max_ts(maps:get(Sender, MRD), Ts),
    MRD#{Sender := NewTs}.

max_ts(Ts1, Ts2) ->
    case compare_vclock(Ts1, Ts2) of
        Res when Res =:= gt orelse Res =:= cc ->
            Ts1;
        _ ->
            Ts2
    end.

min_ts(Ts1, Ts2) ->
    case compare_vclock(Ts1, Ts2) of
        gt ->
            Ts2;
        _ ->
            Ts1
    end.

-spec send_stable_ts(state()) -> ok.
send_stable_ts(#state{mrd = MRD,
                      stabiliser_pid = Pid,
                      stable_ts = CurStableTs})
    when is_pid(Pid) ->
    StableTs =
        maps:fold(fun(_Node, Ts, MinTs) -> min_ts(MinTs, Ts) end,
                  element(2, hd(maps:to_list(MRD))),
                  MRD),
    dbg_out("stable ts ~p current ~p ~n mrd ~p~n", [StableTs, CurStableTs, MRD]),
    case compare_vclock(StableTs, CurStableTs) of
        Res when Res =/= eq ->
            dbg_out("sending stable ts ~p~n", [StableTs]),
            Pid ! {stable_ts, StableTs},
            StableTs;
        _ ->
            % io:format("not sending stable ts ~p ~p~n", [StableTs, CurStableTs]),
            CurStableTs
    end;
send_stable_ts(_State = #state{stable_ts = StableTs}) ->
    StableTs.

%% @doc Deps is the vector clock of the event
%% Delivered is the local vector clock
%% @end
-spec msg_deliverable(vclock(), vclock(), node()) -> boolean().
msg_deliverable(Deps, Delivered, Sender) ->
    OtherDeps = maps:remove(Sender, Deps),
    OtherDelivered = maps:remove(Sender, Delivered),
    maps:get(Sender, Deps) == maps:get(Sender, Delivered) + 1
    andalso vclock_leq(OtherDeps, OtherDelivered).

-spec new_clock() -> vclock().
new_clock() ->
    new_clock([node() | nodes()]).

new_clock(Nodes) ->
    dbg_out("new clock with nodes ~p~n", [[node() | nodes()]]),
    maps:from_keys(Nodes, 0).

-spec new_mrds() -> #{node() => vclock()}.
new_mrds() ->
    new_mrds([node() | nodes()]).

new_mrds(Nodes) ->
    maps:from_keys(Nodes, new_clock(Nodes)).

-spec increment(node(), vclock()) -> vclock().
increment(Node, C) ->
    C#{Node := maps:get(Node, C, 0) + 1}.

%% @doc convenience function for comparing two vector clocks, true when VC1 <= VC2
-spec vclock_leq(vclock(), vclock()) -> boolean().
vclock_leq(VC1, VC2) ->
    R = compare_vclock(VC1, VC2),
    R =:= eq orelse R =:= lt.

-spec compare_vclock([integer()], [integer()]) -> ord().
compare_vclock(VC1, VC2) when map_size(VC1) == 0 andalso map_size(VC2) == 0 ->
    eq;
compare_vclock(VC1, _VC2) when map_size(VC1) == 0 ->
    lt;
compare_vclock(_VC1, VC2) when map_size(VC2) == 0 ->
    gt;
compare_vclock(VClock1, VClock2) ->
    AllKeys =
        maps:keys(
            maps:merge(VClock1, VClock2)),
    {Ls, Gs} =
        lists:foldl(fun(Key, {L, G}) ->
                       C1 = maps:get(Key, VClock1, 0),
                       C2 = maps:get(Key, VClock2, 0),
                       if C1 < C2 -> {L + 1, G};
                          C1 > C2 -> {L, G + 1};
                          true -> {L, G}
                       end
                    end,
                    {0, 0},
                    AllKeys),
    if Ls == 0 andalso Gs == 0 ->
           eq;
       Ls == 0 ->
           gt;
       Gs == 0 ->
           lt;
       true ->
           cc
    end.
