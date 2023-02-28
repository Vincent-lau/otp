-module(mnesia_causal).

-export([start/0, get_ts/0, send_msg/0, rcv_msg/3, rcv_msg/4, compare_vclock/2,
         deliver_one/1]).
-export([init/1, handle_call/3, handle_cast/2]).
-export([get_buffered/0, new/0]).

-include("mnesia.hrl").

-import(mnesia_lib, [important/2, dbg_out/2, verbose/2, warning/2]).

-behaviour(gen_server).

-type ord() :: lt | eq | gt | cc.
-type lc() :: integer().
-type vclock() :: #{node() => lc()}.
-type msg() :: #commit{}.

-record(state, {send_seq :: integer(), delivered :: vclock(), buffer :: [mmsg()]}).
-record(mmsg, {tid :: pid(), tab :: mnesia:table(), msg :: msg(), from :: pid()}).

-type mmsg() :: #mmsg{}.

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
deliver_one(#commit{sender = Sender}) ->
    gen_server:call(?MODULE, {deliver_one, Sender}).

%% gen_server callbacks
init(_Args) ->
    {ok,
     #state{send_seq = 0,
            delivered = new(),
            buffer = []}}.

handle_call(get_buf, _From, #state{buffer = Buffer} = State) ->
    {reply, Buffer, State};
handle_call(get_ts, _From, #state{delivered = D} = State) ->
    {reply, D, State};
handle_call(send_msg, _From, State = #state{delivered = Delivered, send_seq = SendSeq}) ->
    Deps = Delivered#{node() := SendSeq + 1},
    {reply, {node(), Deps}, State#state{send_seq = SendSeq + 1}};
handle_call({deliver_one, Sender}, _From, State = #state{delivered = Delivered}) ->
    NewDelivered = increment(Sender, Delivered),
    {reply, ok, State#state{delivered = NewDelivered}};
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
%% where we guarantee that if the input message is deliverable then it is at the
%% tail of the list
%% @end
-spec find_deliverable(mmsg(), vclock(), [mmsg()]) -> {vclock(), [mmsg()], [mmsg()]}.
find_deliverable(MM = #mmsg{msg = #commit{ts = Deps, sender = Sender}},
                 Delivered,
                 Buffer) ->
    case msg_deliverable(Deps, Delivered, Sender) of
        true ->
            dbg_out("input message ~p deliverable~n", [MM]),
            NewDelivered = increment(Sender, Delivered),
            do_find_deliverable(NewDelivered, Buffer, [MM]);
        false ->
            dbg_out("input message ~p not deliverable~n", [MM]),
            {Delivered, Buffer, []}
    end.

-spec do_find_deliverable(vclock(), [mmsg()], [mmsg()]) -> {vclock(), [mmsg()], [mmsg()]}.
do_find_deliverable(Delivered, Buff, Deliverable) ->
    {Dev, NDev} =
        lists:partition(fun(#mmsg{msg = #commit{ts = Deps, sender = Sender}}) ->
                           msg_deliverable(Deps, Delivered, Sender)
                        end,
                        Buff),
    case Dev of
        [] ->
            {Delivered, NDev, Deliverable};
        Dev when length(Dev) > 0 ->
            NewDelivered =
                lists:foldl(fun(#mmsg{msg = #commit{sender = Sender}}, AccIn) ->
                               increment(Sender, AccIn)
                            end,
                            Delivered,
                            Dev),
            do_find_deliverable(NewDelivered, NDev, Dev ++ Deliverable)
    end.

    % verbose("non deliverable first 10 ~p~n", [lists:sublist(NDev, 10)]),
    % verbose("non deliverable last 10 ~p~n current delivered ~p~n",
    %         [lists:sublist(NDev, max(length(NDev) - 11, 1), 10), Delivered]),

%% @doc Deps is the vector clock of the event
%% Delivered is the local vector clock
%% @end
-spec msg_deliverable(vclock(), vclock(), node()) -> boolean().
msg_deliverable(Deps, Delivered, Sender) ->
    OtherDeps = maps:remove(Sender, Deps),
    OtherDelivered = maps:remove(Sender, Delivered),
    case maps:get(Sender, Deps) == maps:get(Sender, Delivered) + 1
         andalso vclock_leq(OtherDeps, OtherDelivered)
    of
        true ->
            true;
        false ->
            false            % case vclock_leq(Deps, Delivered) of
                             %     true ->
                             %         warning("new message with lower clock ~p than delivered ~p~n",
                             %                 [Deps, Delivered]),
                             %         true;
                             %     _Other ->
                             %         false
                             % end
    end.

% -spec update_vclock(vclock(), vclock(), integer()) -> vclock().
% update_vclock(Node, EvnClk, MyClk) ->
%     TakeLarger = fun(K, _V) -> max(maps:get(EvnClk, K, 1), maps:get(MyClk, K)) end,
%     maps:map(TakeLarger, EvnClk),
%     increment(Node, MyClk).

-spec new() -> vclock().
new() ->
    dbg_out("new clock with nodes ~p~n", [[node() | nodes()]]),
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
