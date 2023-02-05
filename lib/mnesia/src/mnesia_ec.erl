-module(mnesia_ec).

-include("mnesia.hrl").

-import(mnesia_lib, [important/2, dbg_out/2, verbose/2]).

-export([lock/4, write/5, delete/5, delete_object/5, read/5, match_object/5, all_keys/4,
         first/3, last/3, prev/4, next/4, index_match_object/6, index_read/6, table_info/4,
         select/5]).
-export([receive_msg/4]).
-export([start/0, init/1]).

-compile([nowarn_unused_vars]).

% -behaviour(mnesia_access).

-record(prep,
        {protocol = sym_trans,
         %% async_dirty | sync_dirty | sym_trans | sync_sym_trans | asym_trans | sync_asym_trans
         records = [],
         prev_tab = [], % initiate to a non valid table name
         prev_types,
         prev_snmp,
         types,
         majority = [],
         sync = false}).
-record(state,
        {coordinators = gb_trees:empty(),
         participants = gb_trees:empty(),
         supervisor,
         blocked_tabs = [],
         dirty_queue = [],
         fixed_tabs = []}).

start() ->
    mnesia_monitor:start_proc(?MODULE, ?MODULE, init, [self()]).

init(Parent) ->
    register(?MODULE, self()),
    process_flag(trap_exit, true),
    process_flag(message_queue_data, off_heap),
    mnesia_monitor:set_env(causal, true),

    case mnesia_tm:val(debug) of
        Debug when Debug /= debug, Debug /= trace ->
            ignore;
        _ ->
            mnesia_subscr:subscribe(whereis(mnesia_event), {table, schema})
    end,
    proc_lib:init_ack(Parent, {ok, self()}),
    doit_loop(#state{supervisor = Parent}).

doit_loop(#state{coordinators = Coordinators,
                 participants = Participants,
                 supervisor = Sup} =
              State) ->
    receive
        {From, {async_ec, Tid, Commit, Tab}} ->
            dbg_out("received async_ec: ~p~n", [{From, {async_ec, Tid, Commit, Tab}}]),
            case lists:member(Tab, State#state.blocked_tabs) of
                false ->
                    mnesia_ec:receive_msg(Tid, Commit, Tab, false),
                    doit_loop(State);
                true ->
                    Item = {async_ec, Tid, mnesia_tm:new_cr_format(Commit), Tab},
                    State2 = State#state{dirty_queue = [Item | State#state.dirty_queue]},
                    doit_loop(State2)
            end
    end.

%% mnesia_access API
%%
lock({async_ec, _Pid}, _Ts, _LockItem, _LockKind) ->
    [];
lock(Tid, Ts, LockItem, LockKind) ->
    mnesia:lock(Tid, Ts, LockItem, LockKind).

write({async_ec, _Pid}, _Ts, Tab, Val, _LockKind)
    when is_atom(Tab), Tab /= schema, is_tuple(Val), tuple_size(Val) > 2 ->
    do_ec_write(async_ec, Tab, Val);
write(Tid, Ts, Tab, Val, LockKind) ->
    mnesia:write(Tid, Ts, Tab, Val, LockKind).

delete({async_ec, _Pid}, Ts, Tab, Key, _LockKind) when is_atom(Tab), Tab /= schema ->
    do_ec_delete(async_ec, Tab, Key);
delete(Tid, Ts, Tab, Val, LockKind) ->
    mnesia:delete(Tid, Ts, Tab, Val, LockKind).

delete_object(Tid, Ts, Tab, Val, LockKind) ->
    ok.

        %    when is_atom(Tab), Tab /= schema, is_tuple(Val), tuple_size(Val) > 2 ->
        %          case has_var(Val) of
        %          false ->
        %              do_delete_object(Tid, Ts, Tab, Val, LockKind);
        %          true ->
        %              abort({bad_type, Tab, Val})
        %          end;
        %      delete_object(_Tid, _Ts, Tab, _Key, _LockKind) ->
        %          abort({bad_type, Tab}).

read({async_ec, _Pid}, _Ts, Tab, Key, _LockKind) when is_atom(Tab), Tab /= schema ->
    ec_read(Tab, Key);
read(_Tid, _Ts, Tab, _Key, _LockKind) ->
    mnesia:abort({bad_type, Tab}).

match_object(Tid, Ts, Tab, Pat, LockKind) ->
    ok.%             when is_atom(Tab), Tab /= schema, is_tuple(Pat), tuple_size(Pat) > 2 ->
       %               case element(1, Tid) of
       %               ets ->
       %                   mnesia_lib:db_match_object(ram_copies, Tab, Pat);
       %               _Protocol ->
       %                   dirty_match_object(Tab, Pat)
       %               end;
       %           match_object(_Tid, _Ts, Tab, Pat, _LockKind) ->
       %               abort({bad_type, Tab, Pat}).

all_keys({async_ec, _Pid} = Tid, Ts, Tab, LockKind) when is_atom(Tab), Tab /= schema ->
    Pat0 = mnesia_tm:val({Tab, wild_pattern}),
    Pat1 =
        erlang:append_element(
            erlang:append_element(Pat0, '_'), write),
    Pat = setelement(2, Pat1, '$1'),
    Keys = select(Tid, Ts, Tab, [{Pat, [], ['$1']}], LockKind),
    case mnesia_tm:val({Tab, setorbag}) of
        bag ->
            mnesia_lib:uniq(Keys);
        _ ->
            Keys
    end;
all_keys(_Tid, _Ts, Tab, _LockKind) ->
    mnesia:abort({bad_type, Tab}).

first({async_ec, _Pid}, _Ts, Tab) when is_atom(Tab), Tab /= schema ->
    ec_first(Tab);
first(_Tid, _Ts, Tab) ->
    mnesia:abort({bad_type, Tab}).

last({async_ec, _Pid}, _Ts, Tab) when is_atom(Tab), Tab /= schema ->
    ec_last(Tab);
last(_Tid, _Ts, Tab) ->
    mnesia:abort({bad_type, Tab}).

prev({async_ec, _Pid}, _Ts, Tab, Key) when is_atom(Tab), Tab /= schema ->
    ec_prev(Tab, Key);
prev(_Tid, _Ts, Tab, _) ->
    mnesia:abort({bad_type, Tab}).

next({async_ec, _pid}, _Ts, Tab, Key) when is_atom(Tab), Tab /= schema ->
    ec_next(Tab, Key);
next(_Tid, _Ts, Tab, _) ->
    mnesia:abort({bad_type, Tab}).

index_match_object(Tid, Ts, Tab, Pat, Attr, LockKind) ->
    ok.%                         when is_atom(Tab), Tab /= schema, is_tuple(Pat), tuple_size(Pat) > 2 ->
       %                           case element(1, Tid) of
       %                           ets ->
       %                               dirty_index_match_object(Tab, Pat, Attr); % Should be optimized?
       %                           tid ->
       %                               case mnesia_schema:attr_tab_to_pos(Tab, Attr) of
       %                                       {_} ->
       %                                           case LockKind of
       %                                               read ->
       %                                       Store = Ts#tidstore.store,
       %                                       mnesia_locker:rlock_table(Tid, Store, Tab),
       %                                       Objs = dirty_match_object(Tab, Pat),
       %                                       add_written_match(Store, Pat, Tab, Objs);
       %                                               _ ->
       %                                                   abort({bad_type, Tab, LockKind})
       %                                           end;
       %                               Pos when Pos =< tuple_size(Pat) ->
       %                                   case LockKind of
       %                                   read ->
       %                                       Store = Ts#tidstore.store,
       %                                       mnesia_locker:rlock_table(Tid, Store, Tab),
       %                                       Objs = dirty_index_match_object(Tab, Pat, Attr),
       %                                       add_written_match(Store, Pat, Tab, Objs);
       %                                   _ ->
       %                                       abort({bad_type, Tab, LockKind})
       %                                   end;
       %                               BadPos ->
       %                                   abort({bad_type, Tab, BadPos})
       %                               end;
       %                           _Protocol ->
       %                               dirty_index_match_object(Tab, Pat, Attr)
       %                           end;
       %                       index_match_object(_Tid, _Ts, Tab, Pat, _Attr, _LockKind) ->
       %                           abort({bad_type, Tab, Pat}).

index_read(Tid, Ts, Tab, Key, Attr, LockKind) ->
    ok.%                           when is_atom(Tab), Tab /= schema ->
       %                             case element(1, Tid) of
       %                             ets ->
       %                                 dirty_index_read(Tab, Key, Attr); % Should be optimized?
       %                             tid ->
       %                                 Pos = mnesia_schema:attr_tab_to_pos(Tab, Attr),
       %                                 case LockKind of
       %                                 read ->
       %                                     case has_var(Key) of
       %                                     false ->
       %                                         Store = Ts#tidstore.store,
       %                                         Objs = mnesia_index:read(Tid, Store, Tab, Key, Pos),
       %                                                     add_written_index(
       %                                                       Ts#tidstore.store, Pos, Tab, Key, Objs);
       %                                     true ->
       %                                         abort({bad_type, Tab, Attr, Key})
       %                                     end;
       %                                 _ ->
       %                                     abort({bad_type, Tab, LockKind})
       %                                 end;
       %                             _Protocol ->
       %                                 dirty_index_read(Tab, Key, Attr)
       %                             end;
       %                         index_read(_Tid, _Ts, Tab, _Key, _Attr, _LockKind) ->
       %                             abort({bad_type, Tab}).

select({async_ec, _Pid}, _Ts, Tab, Spec, _LockKind) ->
    ec_select(Tab, Spec);
select(Tid, Ts, Tab, Spec, LockKind) ->
    mnesia:select(Tid, Ts, Tab, Spec, LockKind).

table_info({asyn_ec, _Pid}, _Ts, Tab, Item) ->
    mnesia:any_table_info(Tab, Item).

%% Private functions, copied or modified from mnesia.erl and mnesia_tm.erl

%% =============== prepare and send ===============
do_ec_write(SyncMode, Tab, Val)
    when is_atom(Tab), Tab /= schema, is_tuple(Val), tuple_size(Val) > 2 ->
    {_, _, _} = mnesia_lib:validate_record(Tab, Val),
    Oid = {Tab, element(2, Val)},
    ec(SyncMode, {Oid, Val, write});
do_ec_write(_SyncMode, Tab, Val) ->
    mnesia:abort({bad_type, Tab, Val}).

do_ec_delete(SyncMode, Tab, Key) when is_atom(Tab), Tab /= schema ->
    Oid = {Tab, Key},
    ec(SyncMode, {Oid, Oid, delete});
do_ec_delete(_SyncMode, Tab, _Key) ->
    mnesia:abort({bad_type, Tab}).

ec(Protocol, Item) ->
    {{Tab, Key}, _Val, _Op} = Item,
    Tid = {ec, self()},
    Prep = prepare_items(Tid, Tab, Key, [Item], #prep{protocol = Protocol}),
    CR = Prep#prep.records,
    dbg_out("ec: ~p~n", [CR]),
    case Protocol of
        async_ec ->
            ReadNode = mnesia_tm:val({Tab, where_to_read}),
            {WaitFor, FirstRes} = async_send_ec(Tid, CR, Tab, ReadNode),
            mnesia_tm:rec_dirty(WaitFor, FirstRes);
        _ ->
            mnesia:abort({bad_activity, Protocol})
    end.

%% Returns a prep record with all items in reverse order
prepare_items(Tid, Tab, Key, Items, Prep) when Prep#prep.prev_tab == Tab ->
    Types = Prep#prep.prev_types,
    Snmp = Prep#prep.prev_snmp,
    Recs = Prep#prep.records,
    Recs2 = do_prepare_items(Tid, Tab, Key, Types, Snmp, Items, Recs),
    Prep#prep{records = Recs2};
prepare_items(Tid, Tab, Key, Items, Prep) ->
    Types = mnesia_tm:val({Tab, where_to_commit}),
    case Types of
        [] ->
            mnesia:abort({no_exists, Tab});
        {blocked, _} ->
            unblocked = req({unblock_me, Tab}),
            prepare_items(Tid, Tab, Key, Items, Prep);
        _ ->
            Majority = mnesia_tm:needs_majority(Tab, Prep),
            Snmp = mnesia_tm:val({Tab, snmp}),
            Recs2 = do_prepare_items(Tid, Tab, Key, Types, Snmp, Items, Prep#prep.records),
            Prep2 =
                Prep#prep{records = Recs2,
                          prev_tab = Tab,
                          majority = Majority,
                          prev_types = Types,
                          prev_snmp = Snmp},
            check_prep(Prep2, Types)
    end.

check_prep(#prep{majority = [], types = Types} = Prep, Types) ->
    Prep;
check_prep(#prep{majority = M, types = undefined} = Prep, Types) ->
    Protocol =
        if M == [] ->
               Prep#prep.protocol;
           true ->
               asym_trans
        end,
    Prep#prep{protocol = Protocol, types = Types};
check_prep(Prep, _Types) ->
    Prep#prep{protocol = asym_trans}.

req(R) ->
    case whereis(?MODULE) of
        undefined ->
            {error, {node_not_running, node()}};
        Pid ->
            Ref = make_ref(),
            Pid ! {{self(), Ref}, R},
            rec(Pid, Ref)
    end.

rec(Pid, Ref) ->
    receive
        {?MODULE, Ref, Reply} ->
            Reply;
        {'EXIT', Pid, _} ->
            {error, {node_not_running, node()}}
    end.

do_prepare_items(Tid, Tab, Key, Types, Snmp, Items, Recs) ->
    Recs2 = mnesia_tm:prepare_snmp(Tid, Tab, Key, Types, Snmp, Items, Recs), % May exit
    Recs3 = mnesia_tm:prepare_nodes(Tid, Types, Items, Recs2, normal),
    verbose("do prepare_items Rec3: ~p ~p ~p ~p~n", [Tid, Types, Items, Recs2]),
    case mnesia_monitor:get_env(causal) of
        true ->
            dbg_out("applying causal delivery~n", []),
            prepare_ts(Recs3);
        false ->
            dbg_out("not applying causal delivery~n", []),
            Recs3
    end.

-spec prepare_ts([#commit{}]) -> [#commit{}].
prepare_ts(Recs) ->
    {Node, Ts} = mnesia_causal:send_msg(),
    do_prepare_ts(lists:reverse(Recs), Node, Ts).

%% Returns a list of commit record, with node and ts set
-spec do_prepare_ts([#commit{}], node(), mnesia_causal:vclock()) ->
                       [#commit{sender :: atom()}].
do_prepare_ts([Hd | Tl], Node, Ts) ->
    % we only add ts once, since we consider all copies in a commit as a whole
    Commit = Hd#commit{sender = Node, ts = Ts},
    [Commit | do_prepare_ts(Tl, Node, Ts)];
% Commit1 = Commit#commit{ram_copies = do_update_ts(ram_copies, Commit#commit.ram_copies)},
% Commit2 =
%     Commit#commit{disc_copies = do_update_ts(disc_copies, Commit1#commit.disc_copies)},
% Commit3 =
%     Commit#commit{disc_only_copies =
%                       do_update_ts(disc_only_copies, Commit2#commit.disc_only_copies)},
% Commit4 = Commit#commit{ext = do_update_ts(ext, Commit3#commit.ext)},
% [Commit4 | do_prepare_ts(Tl, Node)];
do_prepare_ts([], _Node, _Ts) ->
    [].

% FIX let's only consider ram_copy for now
do_update_ts(ram_copies, Copies, Ts) ->
    [add_time(Copy, Ts) || Copy <- Copies];
do_update_ts(disc_copies, Copies, Ts) ->
    Copies;
do_update_ts(disc_only_copies, Copies, Ts) ->
    Copies;
do_update_ts(ext, ExtCopies, Ts) ->
    ExtCopies;
% {_Node, Ts} = mnesia_causal:send_msg(),
% case ExtCopies of
%     [{ext_copies, Copies}] ->
%         NewExtCopies = [add_time(Copy, Ts) || Copy <- Copies],
%         [{ext_copies, NewExtCopies}];
%     Other ->
%         Other
% end;
do_update_ts(Storage, Copies, Ts) ->
    mnesia:abort({bad_storage, Storage}).

add_time({Oid, Val, Op}, Ts) ->
    {Oid, {Val, Ts}, Op};
add_time({ExtInfo = {ext, porset_copies, mnesia_porset}, {Oid, Val, write}}, Ts) ->
    {ExtInfo, {Oid, {Val, Ts}, write}};
add_time({ExtInfo = {ext, porset_copies, mnesia_porset},
          {_Oid = {Tab, Key}, Val, delete}},
         Ts) ->
    {ExtInfo, {{Tab, {Key, Ts}}, Val, delete}};
add_time({ExtInfo = {ext, porset_copies, mnesia_porset}, {Oid, Val, Op}}, Ts) ->
    {ExtInfo, {Oid, {Val, Ts}, Op}};
add_time(ExtCopy, _Commit) ->
    % adding time to each element in the commit is porset specific
    ExtCopy.

receive_msg(Tid, Commit, Tab, true) ->
    true = do_receive_msg(Tid, Commit, Tab),
    do_ec(Tid, Commit);
receive_msg(Tid, Commit, Tab, false) ->
    case do_receive_msg(Tid, Commit, Tab) of
        true ->
            do_async_ec(Tid, mnesia_tm:new_cr_format(Commit), Tab);
        false ->
            ok
    end.

%% @doc This function finds all the deliverable commits in the buffer and delivers them
%% @returns whether the input message should be delivered, and if should be delivered
%% when it is in the list of deliverables or we are not using causal broadcast.
%% @end
-spec do_receive_msg(term(), #commit{}, atom()) -> boolean().
do_receive_msg(Tid, Commit, Tab) ->
    case mnesia_monitor:get_env(causal) of
        true ->
            D = mnesia_causal:rcv_msg(Tid, Commit, Tab),
            dbg_out("found devliverable commits: ~p~n", [D]),
            {Deliverable, Local} =
                lists:partition(fun(DInfo) -> DInfo =/= {Tid, Commit, Tab} end, D),
            lists:foreach(fun({Tid1, Commit1, Tab1}) ->
                             do_async_ec(Tid1, mnesia_tm:new_cr_format(Commit1), Tab1)
                          end,
                          Deliverable),
            length(Local) > 0;
        false ->
            % if we are not using causal broadcast, we deliver all the messages
            true
    end.

%% @returns {WaitFor, Res}
async_send_ec(_Tid, _Nodes, Tab, nowhere) ->
    {[], {'EXIT', {aborted, {no_exists, Tab}}}};
async_send_ec(Tid, Nodes, Tab, ReadNode) ->
    async_send_ec(Tid, Nodes, Tab, ReadNode, [], ok).

async_send_ec(Tid, [Head | Tail], Tab, ReadNode, WaitFor, Res) ->
    dbg_out("async_send_ec Nodes: ~p~n", [[Head | Tail]]),
    Node = Head#commit.node,
    if ReadNode == Node, Node == node() ->
           NewRes = receive_msg(Tid, Head, Tab, true),
           async_send_ec(Tid, Tail, Tab, ReadNode, WaitFor, NewRes);
       ReadNode == Node ->
           {?MODULE, Node} ! {self(), {async_ec, Tid, Head, Tab}},
           NewRes = {'EXIT', {aborted, {node_not_running, Node}}},
           async_send_ec(Tid, Tail, Tab, ReadNode, [Node | WaitFor], NewRes);
       true ->
           {?MODULE, Node} ! {self(), {async_ec, Tid, Head, Tab}},
           dbg_out("sending ~p to ~p~n", [{async_ec, Tid, Head, Tab}, {?MODULE, Node}]),
           async_send_ec(Tid, Tail, Tab, ReadNode, WaitFor, Res)
    end;
async_send_ec(_Tid, [], _Tab, _ReadNode, WaitFor, Res) ->
    {WaitFor, Res}.

%%% =============== Receiving and update ===================

do_async_ec(Tid, Commit, _Tab) ->
    ?eval_debug_fun({?MODULE, async_ec, pre}, [{tid, Tid}]),
    do_ec(Tid, Commit),
    ?eval_debug_fun({?MODULE, async_ec, post}, [{tid, Tid}]).

do_ec(Tid, Commit) when Commit#commit.schema_ops == [] ->
    mnesia_log:log(Commit),
    do_commit(Tid, Commit).

%% do_commit(Tid, CommitRecord)
do_commit(Tid, Bin) when is_binary(Bin) ->
    do_commit(Tid, binary_to_term(Bin));
do_commit(Tid, C) ->
    do_commit(Tid, C, optional).

do_commit(Tid, Bin, DumperMode) when is_binary(Bin) ->
    do_commit(Tid, binary_to_term(Bin), DumperMode);
do_commit(Tid, C, DumperMode) ->
    mnesia_dumper:update(Tid, C#commit.schema_ops, DumperMode),
    R = mnesia_tm:do_snmp(Tid, proplists:get_value(snmp, C#commit.ext, [])),
    RCopies = do_update_ts(ram_copies, C#commit.ram_copies, C#commit.ts),
    R2 = do_update(Tid, ram_copies, RCopies, R),
    % TODO update other copies as well
    R3 = do_update(Tid, disc_copies, C#commit.disc_copies, R2),
    R4 = do_update(Tid, disc_only_copies, C#commit.disc_only_copies, R3),
    R5 = do_update_ext(Tid, C#commit.ext, R4),
    mnesia_subscr:report_activity(Tid),
    R5.

%% This could/should be optimized
do_update_ext(_Tid, [], OldRes) ->
    OldRes;
do_update_ext(Tid, Ext, OldRes) ->
    case lists:keyfind(ext_copies, 1, Ext) of
        false ->
            OldRes;
        {_, Ops} ->
            Do = fun({{ext, _, _} = Storage, Op}, R) -> do_update(Tid, Storage, [Op], R) end,
            lists:foldl(Do, OldRes, Ops)
    end.

%% Update the items
do_update(Tid, Storage, [Op | Ops], OldRes) ->
    try do_update_op(Tid, Storage, Op) of
        ok ->
            do_update(Tid, Storage, Ops, OldRes);
        NewRes ->
            do_update(Tid, Storage, Ops, NewRes)
    catch
        _:Reason:ST ->
            %% This may only happen when we recently have
            %% deleted our local replica, changed storage_type
            %% or transformed table
            %% BUGBUG: Updates may be lost if storage_type is changed.
            %%         Determine actual storage type and try again.
            %% BUGBUG: Updates may be lost if table is transformed.
            verbose("do_update in ~w failed: ~tp -> {'EXIT', ~tp}~n", [Tid, Op, {Reason, ST}]),
            do_update(Tid, Storage, Ops, OldRes)
    end;
do_update(_Tid, _Storage, [], Res) ->
    Res.

do_update_op(Tid, Storage, {{Tab, K}, Obj, write}) ->
    commit_write(?catch_val({Tab, commit_work}), Tid, Storage, Tab, K, Obj, undefined),
    mnesia_porset:db_put(Storage, Tab, Obj);
do_update_op(Tid, Storage, {{Tab, K}, Obj, delete}) ->
    commit_delete(?catch_val({Tab, commit_work}), Tid, Storage, Tab, K, Obj, undefined),
    % we send Obj instead of Key for processing
    mnesia_porset:db_erase(Storage, Tab, Obj);
do_update_op(Tid, Storage, {{Tab, K}, {RecName, Incr}, update_counter}) ->
    {NewObj, OldObjs} =
        try
            NewVal = mnesia_lib:db_update_counter(Storage, Tab, K, Incr),
            true = is_integer(NewVal) andalso NewVal >= 0,
            {{RecName, K, NewVal}, [{RecName, K, NewVal - Incr}]}
        catch
            error:_ when Incr > 0 ->
                New = {RecName, K, Incr},
                mnesia_lib:db_put(Storage, Tab, New),
                {New, []};
            error:_ ->
                Zero = {RecName, K, 0},
                mnesia_lib:db_put(Storage, Tab, Zero),
                {Zero, []}
        end,
    commit_update(?catch_val({Tab, commit_work}), Tid, Storage, Tab, K, NewObj, OldObjs),
    element(3, NewObj);
do_update_op(Tid, Storage, {{Tab, Key}, Obj, delete_object}) ->
    commit_del_object(?catch_val({Tab, commit_work}), Tid, Storage, Tab, Key, Obj),
    mnesia_lib:db_match_erase(Storage, Tab, Obj);
do_update_op(Tid, Storage, {{Tab, Key}, Obj, clear_table}) ->
    commit_clear(?catch_val({Tab, commit_work}), Tid, Storage, Tab, Key, Obj),
    mnesia_lib:db_match_erase(Storage, Tab, Obj).

commit_write([], _, _, _, _, _, _) ->
    ok;
commit_write([{checkpoints, CpList} | R], Tid, Storage, Tab, K, Obj, Old) ->
    mnesia_checkpoint:tm_retain(Tid, Tab, K, write, CpList),
    commit_write(R, Tid, Storage, Tab, K, Obj, Old);
commit_write([H | R], Tid, Storage, Tab, K, Obj, Old) when element(1, H) == subscribers ->
    mnesia_subscr:report_table_event(H, Tab, Tid, Obj, write, Old),
    commit_write(R, Tid, Storage, Tab, K, Obj, Old);
commit_write([H | R], Tid, Storage, Tab, K, Obj, Old) when element(1, H) == index ->
    mnesia_index:add_index(H, Storage, Tab, K, Obj, Old),
    commit_write(R, Tid, Storage, Tab, K, Obj, Old).

commit_update([], _, _, _, _, _, _) ->
    ok;
commit_update([{checkpoints, CpList} | R], Tid, Storage, Tab, K, Obj, _) ->
    Old = mnesia_checkpoint:tm_retain(Tid, Tab, K, write, CpList),
    commit_update(R, Tid, Storage, Tab, K, Obj, Old);
commit_update([H | R], Tid, Storage, Tab, K, Obj, Old)
    when element(1, H) == subscribers ->
    mnesia_subscr:report_table_event(H, Tab, Tid, Obj, write, Old),
    commit_update(R, Tid, Storage, Tab, K, Obj, Old);
commit_update([H | R], Tid, Storage, Tab, K, Obj, Old) when element(1, H) == index ->
    mnesia_index:add_index(H, Storage, Tab, K, Obj, Old),
    commit_update(R, Tid, Storage, Tab, K, Obj, Old).

commit_delete([], _, _, _, _, _, _) ->
    ok;
commit_delete([{checkpoints, CpList} | R], Tid, Storage, Tab, K, Obj, _) ->
    Old = mnesia_checkpoint:tm_retain(Tid, Tab, K, delete, CpList),
    commit_delete(R, Tid, Storage, Tab, K, Obj, Old);
commit_delete([H | R], Tid, Storage, Tab, K, Obj, Old)
    when element(1, H) == subscribers ->
    mnesia_subscr:report_table_event(H, Tab, Tid, Obj, delete, Old),
    commit_delete(R, Tid, Storage, Tab, K, Obj, Old);
commit_delete([H | R], Tid, Storage, Tab, K, Obj, Old) when element(1, H) == index ->
    mnesia_index:delete_index(H, Storage, Tab, K),
    commit_delete(R, Tid, Storage, Tab, K, Obj, Old).

commit_del_object([], _, _, _, _, _) ->
    ok;
commit_del_object([{checkpoints, CpList} | R], Tid, Storage, Tab, K, Obj) ->
    mnesia_checkpoint:tm_retain(Tid, Tab, K, delete_object, CpList),
    commit_del_object(R, Tid, Storage, Tab, K, Obj);
commit_del_object([H | R], Tid, Storage, Tab, K, Obj) when element(1, H) == subscribers ->
    mnesia_subscr:report_table_event(H, Tab, Tid, Obj, delete_object),
    commit_del_object(R, Tid, Storage, Tab, K, Obj);
commit_del_object([H | R], Tid, Storage, Tab, K, Obj) when element(1, H) == index ->
    mnesia_index:del_object_index(H, Storage, Tab, K, Obj),
    commit_del_object(R, Tid, Storage, Tab, K, Obj).

commit_clear([], _, _, _, _, _) ->
    ok;
commit_clear([{checkpoints, CpList} | R], Tid, Storage, Tab, K, Obj) ->
    mnesia_checkpoint:tm_retain(Tid, Tab, K, clear_table, CpList),
    commit_clear(R, Tid, Storage, Tab, K, Obj);
commit_clear([H | R], Tid, Storage, Tab, K, Obj) when element(1, H) == subscribers ->
    mnesia_subscr:report_table_event(H, Tab, Tid, Obj, clear_table, undefined),
    commit_clear(R, Tid, Storage, Tab, K, Obj);
commit_clear([H | R], Tid, Storage, Tab, K, Obj) when element(1, H) == index ->
    mnesia_index:clear_index(H, Tab, K, Obj),
    commit_clear(R, Tid, Storage, Tab, K, Obj).

%% =============== read operations ===============

ec_read(Tab, Key) ->
    mnesia_porset:db_get(Tab, Key).

ec_select(Tab, Spec) ->
    mnesia_porset:db_select(Tab, Spec).

ec_first(Tab) ->
    mnesia_porset:db_first(Tab).

ec_last(Tab) ->
    mnesia_porset:db_last(Tab).

ec_prev(Tab, Key) ->
    mnesia_porset:db_prev_key(Tab, Key).

ec_next(Tab, Key) ->
    mnesia_porset:db_next_key(Tab, Key).
