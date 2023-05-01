-module(mnesia_causal).

-export([start/0, get_ts/0, send_msg/0, rcv_msg/3, rcv_msg/4, compare_vclock/2,
         vclock_leq/2, deliver_one/1, tcstable/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([get_buffered/0, get_mrd/0, new_clock/0, bot/0, is_bot/1, reset_with_nodes/1,
         reg_stabiliser/1]).

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
         stabiliser :: {pid(), reference()}}).
-record(mmsg, {tid :: pid(), tab :: mnesia:table(), msg :: msg(), from :: pid()}).

-type mmsg() :: #mmsg{}.
-type mrd() :: #{node() => vclock()}.
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

-spec tcstable(vclock(), node()) -> boolean().
tcstable(Ts, Sender) ->
    gen_server:call(?MODULE, {tcstable, Ts, Sender}).

-spec reg_stabiliser(pid()) -> ok.
reg_stabiliser(ReceiverPid) ->
    gen_server:cast(?MODULE, {reg_stabiliser, ReceiverPid}).

reset_with_nodes(Nodes) ->
    gen_server:call(?MODULE, {reset, Nodes}).

%% ====================gen_server callbacks====================
init([Nodes]) ->
    {ok,
     #state{send_seq = 0,
            delivered = new_clock(Nodes),
            buffer = [],
            mrd = new_mrds(Nodes)}};
init(_Args) ->
    {ok,
     #state{send_seq = 0,
            delivered = new_clock(),
            buffer = [],
            mrd = new_mrds()}}.

handle_call(send_msg, _From, State = #state{delivered = Delivered, send_seq = SendSeq}) ->
    Deps = Delivered#{node() := SendSeq + 1},
    {reply, {node(), Deps}, State#state{send_seq = SendSeq + 1}};
handle_call({deliver_one, Sender, Ts},
            _From,
            State =
                #state{delivered = Delivered,
                       mrd = MRD,
                       stabiliser = Stabiliser}) ->
    NewDelivered = increment(Sender, Delivered),
    MRD2 = update_mrd(MRD, Sender, Ts),
    send_ts(Stabiliser, Ts, Sender),
    {reply, ok, State#state{delivered = NewDelivered, mrd = MRD2}};
handle_call({receive_msg, MM = #mmsg{msg = #commit{sender = Sender, ts = Ts}}},
            _From,
            State = #state{stabiliser = Stabiliser}) ->
    send_ts(Stabiliser, Ts, Sender),
    {NewState, Deliverable} = find_deliverable(MM, State),
    {reply, Deliverable, NewState};
handle_call({tcstable, Ts, Sender}, _From, State = #state{mrd = MRD}) ->
    case Ts of
        #{} when map_size(Ts) == 0 ->
            {reply, true, State};
        Other when is_map(Other) ->
            Res = maps:get(Sender, Ts) =< low(MRD, Sender),
            io:format("tcstable: ~p ~p ~p ~p~n", [Res, Ts, MRD, Sender]),
            {reply, Res, State}
    end;
handle_call(get_buf, _From, #state{buffer = Buffer} = State) ->
    {reply, Buffer, State};
handle_call(get_ts, _From, #state{delivered = D} = State) ->
    {reply, D, State};
handle_call(get_mrd, _From, #state{mrd = MRD} = State) ->
    {reply, MRD, State};
handle_call({reset, Nodes}, _From, #state{stabiliser = Stabiliser}) ->
    {ok, NewState} = init([Nodes]),
    {reply, ok, NewState#state{stabiliser = Stabiliser}}.

handle_cast({reg_stabiliser, ReceiverPid}, State) ->
    TMap =
        maps:from_keys(
            maps:keys(State#state.mrd), []),
    {Pid, Ref} = spawn_monitor(fun() -> stable_ts_sender(ReceiverPid, TMap) end),
    erlang:send_after(1000, Pid, periodic_check_stability),
    {noreply, State#state{stabiliser = {Pid, Ref}}}.

handle_info({'DOWN', Ref, process, Pid, Reason},
            State = #state{stabiliser = {Pid, Ref}}) ->
    warning("stabiliser process ~p died with reason ~p~n", [Pid, Reason]),
    {noreply, State#state{stabiliser = undefined}};
handle_info(Msg, State) ->
    warning("unhandled message ~p~n", [Msg]),
    {noreply, State}.

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
            do_find_deliverable(State#state{delivered = NewDelivered,
                                            buffer = Buffer,
                                            mrd = MRD2},
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
                               StateIn#state{delivered = Dev2, mrd = MRD2}
                            end,
                            State,
                            Dev),
            do_find_deliverable(State2#state{buffer = NDev}, Dev ++ Deliverable)
    end.

-spec update_mrd(#{node() => vclock()}, node(), vclock()) -> #{node() => vclock()}.
update_mrd(MRD, Sender, Ts) ->
    MRD#{Sender := Ts}.

% max_ts(Ts1, Ts2) ->
%     case compare_vclock(Ts1, Ts2) of
%         Res when Res =:= gt orelse Res =:= cc ->
%             Ts1;
%         _ ->
%             Ts2
%     end.

% min_ts(Ts1, Ts2) ->
%     case compare_vclock(Ts1, Ts2) of
%         gt ->
%             Ts2;
%         _ ->
%             Ts1
%     end.

-spec low(mrd(), node()) -> integer().
low(Mrd, Node) ->
    Values = maps:values(Mrd),
    Lows = [maps:get(Node, VClock) || VClock <- Values],
    lists:min(Lows).

-spec stable_ts_sender(pid(), #{node() => [vclock()]}) -> ok.
stable_ts_sender(To, TMap) ->
    receive
        {ts, T, Sender} ->
            % case node() of
            %     'bench1@vincent-pc' ->
            %         io:format("received ts ~p from ~p~n", [T, Sender]);
            %     _ ->
            %         ok
            % end,
            % io:format("current tmap~p~n", [TMap]),
            Ts = maps:get(Sender, TMap),
            TMap2 = maps:put(Sender, [T | Ts], TMap),
            stable_ts_sender(To, TMap2);
        periodic_check_stability ->
            case node() of
                'bench2@vincent-pc' ->
                    io:format("~p current tmap ~p~n mrd ~p~n",
                              [node(), TMap, mnesia_causal:get_mrd()]);
                _ ->
                    ok
            end,
            TMap2 = maps:map(fun(Sender, Ts) -> find_send_stable(Ts, Sender, To) end, TMap),
            erlang:send_after(1000, self(), periodic_check_stability),
            stable_ts_sender(To, TMap2);
        Unexpected ->
            error({unexpected, Unexpected})
    end.

%% @returns a list of vector clocks that are not stable, stable ones are sent
-spec find_send_stable([vclock()], node(), pid()) -> [vclock()].
find_send_stable(Ts, Sender, To) ->
    {Stable, Unstable} = lists:partition(fun(T1) -> tcstable(T1, Sender) end, Ts),
    [To ! {add_timestamp, T1} || T1 <- Stable],
    case node() of
        'bench2@vincent-pc' ->
            io:format("send unstable stable ~p ~n", [Stable]);
        _ ->
            ok
    end,
    Unstable.

-spec send_ts({pid(), reference()}, vclock(), node()) -> ok.
send_ts({Pid, _Ref}, T, Sender) when is_pid(Pid) ->
    Pid ! {ts, T, Sender},

    % io:format("sent ts ~p to ~p~n", [T, Sender]),
    ok;
send_ts(_Stabiliser, _T, _Sender) ->
    ok.

% -spec send_stable_ts(state()) -> ok.
% send_stable_ts(#state{mrd = MRD,
%                       stabiliser_pid = Pid,
%                       stable_ts = CurStableTs})
%     when is_pid(Pid) ->
%     dbg_out("stable ts ~p current ~p ~n mrd ~p~n", [StableTs, CurStableTs, MRD]),
%         Res when Res =/= eq ->
%             dbg_out("sending stable ts ~p~n", [StableTs]),
%             Pid ! {stable_ts, StableTs},
%             StableTs;
%         _ ->
%             % io:format("not sending stable ts ~p ~p~n", [StableTs, CurStableTs]),
%             CurStableTs
%     end;
% send_stable_ts(_State = #state{stable_ts = StableTs}) ->
%     StableTs.

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
