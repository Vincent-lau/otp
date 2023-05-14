-module(mnesia_causal).

-export([start/0, get_ts/0, send_msg/0, rcv_msg/4, compare_vclock/2, vclock_leq/2,
         deliver_one/1, tcstable/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([get_buffered/0, get_mrd/0, new_clock/0, bot/0, is_bot/1, reset_with_nodes/1]).

-include("mnesia.hrl").

-import(mnesia_lib, [important/2, dbg_out/2, verbose/2, warning/2]).

-behaviour(gen_server).

-type ord() :: lt | eq | gt | cc.
-type vclock() :: #{}.
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

-spec send_msg() -> vclock().
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
-spec rcv_msg(pid(), #commit{}, mnesia:table(), {atom(), pid()}) ->
                 [{pid(), #commit{}, mnesia:table()}].
rcv_msg(Tid, Commit, Tab, {async, SendBack}) ->
    gen_server:call(?MODULE,
                    {receive_msg,
                     #mmsg{tid = Tid,
                           msg = Commit,
                           tab = Tab},
                     SendBack});
rcv_msg(Tid, Commit, Tab, {sync, From}) ->
    gen_server:call(?MODULE,
                    {receive_msg,
                     #mmsg{tid = Tid,
                           msg = Commit,
                           tab = Tab,
                           from = From}}).

-spec deliver_one(#commit{}) -> ok.
deliver_one(#commit{ts = Ts}) ->
    Sender = ts_src(Ts),
    gen_server:cast(?MODULE, {deliver_one, Sender, Ts}).

-spec tcstable(vclock()) -> boolean().
tcstable(Ts) ->
    gen_server:call(?MODULE, {tcstable, Ts}).

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
    {reply, Deps, State#state{send_seq = SendSeq + 1}};
handle_call({receive_msg, MM = #mmsg{msg = #commit{}}, SendBack},
            From,
            State = #state{}) ->
    gen_server:reply(From, ok),
    {NewState, Deliverable} = find_deliverable(MM, State),
    Res = [{D#mmsg.tid, D#mmsg.msg, D#mmsg.tab} || D <- Deliverable],
    SendBack ! {?MODULE, {deliver, Res}},
    {noreply, NewState};
handle_call({receive_msg, MM = #mmsg{msg = #commit{}}}, _From, State = #state{}) ->
    {NewState, Deliverable} = find_deliverable(MM, State),
    Res = [{D#mmsg.tid, D#mmsg.msg, D#mmsg.tab, D#mmsg.from} || D <- Deliverable],
    {reply, Res, NewState};
handle_call({tcstable, Ts}, _From, State = #state{mrd = MRD}) ->
    case Ts of
        #{} when map_size(Ts) == 0 ->
            {reply, true, State};
        Other when is_map(Other) ->
            Sender = ts_src(Ts),
            Res = maps:get(Sender, Ts) =< low(MRD, Sender),
            case node() =/= ts_src(Ts) of
                true ->
                    ok;
                % io:format("tcstable: ~p ~p ~p ~p~n", [Res, Ts, MRD, Sender]);
                _ ->
                    ok
            end,
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

handle_cast({deliver_one, Sender, Ts},
            State = #state{delivered = Delivered, mrd = MRD}) ->
    NewDelivered = increment(Sender, Delivered),
    MRD2 = update_mrd(MRD, Sender, Ts),
    {noreply, State#state{delivered = NewDelivered, mrd = MRD2}};
handle_cast(_Msg, State) ->
    {noreply, State}.

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
-spec find_deliverable(mmsg(), state()) -> {state(), [mmsg()]}.
find_deliverable(MM = #mmsg{msg = #commit{ts = Deps}},
                 State =
                     #state{delivered = Delivered,
                            buffer = Buffer,
                            mrd = MRD}) ->
    case msg_deliverable(Deps, Delivered) of
        true ->
            dbg_out("input message ~p deliverable~n", [MM]),
            Sender = ts_src(Deps),
            NewDelivered = increment(Sender, Delivered),
            MRD2 = update_mrd(MRD, Sender, Deps),
            do_find_deliverable(State#state{delivered = NewDelivered,
                                            buffer = Buffer,
                                            mrd = MRD2},
                                [MM]);
        false ->
            dbg_out("input message ~p not deliverable~n", [MM]),
            Buffer2 = [MM | Buffer],
            {State#state{buffer = Buffer2}, []}
    end.

-spec do_find_deliverable(state(), [mmsg()]) -> {state(), [mmsg()]}.
do_find_deliverable(State = #state{delivered = Delivered, buffer = Buff}, Deliverable) ->
    {Dev, NDev} =
        lists:partition(fun(#mmsg{msg = #commit{ts = Deps}}) -> msg_deliverable(Deps, Delivered)
                        end,
                        Buff),
    case Dev of
        [] ->
            {State, Deliverable};
        Dev when length(Dev) > 0 ->
            State2 =
                lists:foldl(fun(#mmsg{msg = #commit{ts = Ts}}, StateIn) ->
                               Sender = ts_src(Ts),
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

-spec ts_src(vclock()) -> node().
ts_src(Ts) ->
    maps:get(sender, Ts).

-spec low(mrd(), node()) -> integer().
low(Mrd, Node) ->
    Values = maps:values(Mrd),
    Lows = [maps:get(Node, VClock) || VClock <- Values],
    lists:min(Lows).

%% @doc Deps is the vector clock of the event
%% Delivered is the local vector clock
%% @end
-spec msg_deliverable(vclock(), vclock()) -> boolean().
msg_deliverable(Deps, Delivered) ->
    Sender = ts_src(Deps),
    OtherDeps = maps:remove(Sender, Deps),
    OtherDelivered = maps:remove(Sender, Delivered),
    maps:get(Sender, Deps) == maps:get(Sender, Delivered) + 1
    andalso vclock_leq(OtherDeps, OtherDelivered).

-spec new_clock() -> vclock().
new_clock() ->
    new_clock([node() | nodes()]).

new_clock(Nodes) ->
    dbg_out("new clock with nodes ~p~n", [[node() | nodes()]]),
    Map = maps:from_keys(Nodes, 0),
    maps:put(sender, node(), Map).

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
    AllNodes =
        maps:keys(
            maps:merge(VClock1, VClock2))
        -- [sender],
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
                    AllNodes),
    if Ls == 0 andalso Gs == 0 ->
           eq;
       Ls == 0 ->
           gt;
       Gs == 0 ->
           lt;
       true ->
           cc
    end.
