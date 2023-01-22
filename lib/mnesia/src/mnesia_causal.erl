-module(mnesia_causal).

-export([start/0, get_ts/0, send_msg/0, rcv_msg/3, compare_vclock/2]).
-export([init/1, handle_call/3, handle_cast/2]).
-export([get_buffered/0, new/0]).

-include("mnesia.hrl").

-behaviour(gen_server).

-type ord() :: lt | eq | gt | cc.
-type lc() :: integer().
-type vclock() :: #{node() => lc()}.
-type msg() :: #commit{}.

-record(state, {send_seq :: integer(), delivered :: vclock(), buffer :: [mmsg()]}).
-record(mmsg, {tid :: pid(), tab :: mnesia:table(), msg :: msg()}).

-type mmsg() :: #mmsg{}.

%% public API

start() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], []).

get_ts() ->
    gen_server:call(?MODULE, get_ts).

-spec send_msg() -> {node(), vclock()}.
send_msg() ->
    gen_server:call(?MODULE, send_msg).

-spec get_buffered() -> [mmsg()].
get_buffered() ->
    gen_server:call(?MODULE, get_buf).

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

%% gen_server callbacks
init(_Args) ->
    {ok,
     #state{send_seq = 0,
            delivered = new(),
            buffer = []}}.

handle_call(get_buf, _From, #state{buffer = Buffer} = State) ->
    {reply, Buffer, State};
handle_call(get_ts, _From, #state{delivered = D} = State) ->
    {reply, {D, erlang:system_time()}, State};
handle_call(send_msg, _From, State = #state{delivered = Delivered, send_seq = SendSeq}) ->
    Deps = Delivered#{node() := SendSeq + 1},
    {reply, {node(), Deps}, State#state{send_seq = SendSeq + 1}};
handle_call({receive_msg, MM = #mmsg{}},
            _From,
            State = #state{delivered = Delivered, buffer = Buffer}) ->
    {NewDelivered, NewBuff, Deliverable} = find_deliverable(MM, Delivered, Buffer),
    {reply, Deliverable, State#state{delivered = NewDelivered, buffer = NewBuff}}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%%% internal functions

%% @doc
%% update the delivered vector clock and buffer
%% @returns {list(), [event()]} the new buffer and events ready to be delivered
%% @end
-spec find_deliverable(mmsg(), vclock(), [mmsg()]) -> {vclock(), [mmsg()], [mmsg()]}.
find_deliverable(MM, Delivered, Buf1) ->
    Buffer = [MM | Buf1],
    do_find_deliverable(Delivered, [], Buffer, []).

-spec do_find_deliverable(vclock(), [mmsg()], [mmsg()], [mmsg()]) ->
                             {vclock(), [mmsg()], [mmsg()]}.
do_find_deliverable(Delivered, Buff, Buff, Deliverable) ->
    {Delivered, Buff, Deliverable};
do_find_deliverable(Delivered, _OldBuff, Buff, Deliverable) ->
    {Dev, NDev} =
        lists:partition(fun(#mmsg{msg = #commit{ts = Deps, sender = Sender}}) ->
                           msg_deliverable(Deps, Delivered, Sender)
                        end,
                        Buff),
    % IncredDev = lists:map(fun update_ts_at_dev/1, Dev),
    NewDelivered =
        lists:foldl(fun(#mmsg{msg = #commit{sender = Sender}}, AccIn) -> increment(Sender, AccIn)
                    end,
                    Delivered,
                    Dev),
    do_find_deliverable(NewDelivered, Buff, NDev, Deliverable ++ Dev).

%% @doc Deps is the vector clock of the event
%% Delivered is the local vector clock
%% @end
-spec msg_deliverable(vclock(), vclock(), node()) -> boolean().
msg_deliverable(Deps, Delivered, Sender) ->
    OtherDeps = maps:remove(Sender, Deps),
    OtherDelivered = maps:remove(Sender, Delivered),
    maps:get(Sender, Deps) == maps:get(Sender, Delivered) + 1
    andalso vclock_leq(OtherDeps, OtherDelivered).

% -spec update_vclock(vclock(), vclock(), integer()) -> vclock().
% update_vclock(Node, EvnClk, MyClk) ->
%     TakeLarger = fun(K, _V) -> max(maps:get(EvnClk, K, 1), maps:get(MyClk, K)) end,
%     maps:map(TakeLarger, EvnClk),
%     increment(Node, MyClk).

-spec new() -> vclock().
new() ->
    maps:from_keys([node() | nodes()], 0).

-spec increment(node(), vclock()) -> vclock().
increment(Node, C) ->
    C#{Node := maps:get(Node, C, 0) + 1}.

%% @doc convenience function for comparing two vector clocks, true when VC1 <= VC2
-spec vclock_leq(vclock(), vclock()) -> boolean().
vclock_leq(VC1, VC2) ->
    R = compare_vclock(VC1, VC2),
    R =:= eq orelse R =:= lt.

-spec compare_vclock([integer()], [integer()]) -> ord().
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
