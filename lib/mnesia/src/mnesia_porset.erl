%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 1996-2022. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%

-module(mnesia_porset).

-export([db_put/3, db_erase/3, db_get/2, db_first/1, db_last_key/1, db_next_key/2,
         db_select/2, db_prev/2]).

-define(DEBUG, 1).

-ifdef(DEBUG).

-define(DBG(DATA), dbg_out("~p:~p: ~p", [?MODULE, ?LINE, DATA])).
-define(DBG(FORMAT, ARGS), dbg_out("~p:~p: " ++ FORMAT, [?MODULE, ?LINE] ++ ARGS)).

-else.

-define(DBG(DATA), ok).
-define(DBG(FORMAT, ARGS), ok).

-endif.

-type op() :: write | delete.
-type val() :: any().
-type ts() :: mnesia_causal:vclock().
-type element() :: {ts(), {op(), val()}}.
-type storage() :: ram_copies | disk_copies | disc_only_copies | {ext, atom(), atom()}.

-import(mnesia_lib, [important/2, dbg_out/2, verbose/2, warning/2]).

-compile([nowarn_unused_function]).

%% types() ->
%%     [{fs_copies, ?MODULE},
%%      {raw_fs_copies, ?MODULE}].

%%% convenience functions

create_schema(Nodes, Aliases) when is_list(Nodes), is_list(Aliases) ->
    mnesia:create_schema(Nodes, [{backend_types, [{A, ?MODULE} || A <- Aliases]}]).

%% Table operations

check_definition(porset_copies, _Tab, _Nodes, _Props) ->
    dbg_out("~p ~p ~p~n", [_Tab, _Nodes, _Props]),
    ok.

create_table(porset_copies, Tab, Props) when is_atom(Tab) ->
    Tid = ets:new(Tab, [public, bag, {keypos, 2}]),
    % Tid = ets:whereis(Name),
    dbg_out("table created 1: ~p with tid ~p and prop ~p~n", [Tab, Tid, Props]),
    mnesia_lib:set({?MODULE, Tab}, Tid),
    ok;
create_table(_, Tag = {Tab, index, {_Where, Type0}}, _Opts) ->
    Type =
        case Type0 of
            ordered ->
                ordered_set;
            _ ->
                Type0
        end,
    Tid = ets:new(Tab, [public, Type]),
    dbg_out("table created 2: tag ~p", [Tag]),
    mnesia_lib:set({?MODULE, Tag}, Tid),
    ok;
create_table(_, Tag = {_Tab, retainer, ChkPName}, _Opts) ->
    Tid = ets:new(ChkPName, [bag, public, {keypos, 2}]),
    dbg_out("table created 3: ~p(~p) ~p", [_Tab, Tid, Tag]),
    mnesia_lib:set({?MODULE, Tag}, Tid),
    ok.

delete_table(porset_copies, Tab) ->
    try
        ets:delete(
            mnesia_lib:val({?MODULE, Tab})),
        mnesia_lib:unset({?MODULE, Tab}),
        ok
    catch
        _:_ ->
            ?DBG({double_delete, Tab}),
            ok
    end.

load_table(porset_copies, _Tab, init_index, _Cs) ->
    ok;
load_table(porset_copies, _Tab, _LoadReason, _Cs) ->
    ?DBG("Load ~p ~p~n", [_Tab, _LoadReason]),
    ok.

%%     mnesia_monitor:unsafe_create_external(Tab, porset_copies, ?MODULE, Cs).

sender_init(Alias, Tab, _RemoteStorage, _Pid) ->
    KeysPerTransfer = 100,
    {standard,
     fun() -> mnesia_lib:db_init_chunk({ext, Alias, ?MODULE}, Tab, KeysPerTransfer) end,
     fun(Cont) -> mnesia_lib:db_chunk({ext, Alias, ?MODULE}, Cont) end}.

receiver_first_message(Sender, {first, Size}, _Alias, Tab) ->
    ?DBG({first, Size}),
    {Size, {Tab, Sender}}.

receive_data(Data, porset_copies, Name, Sender, {Name, Tab, Sender} = State) ->
    ?DBG({Data, State}),
    true = ets:insert(Tab, Data),
    {more, State};
receive_data(Data, Alias, Tab, Sender, {Name, Sender}) ->
    receive_data(Data, Alias, Tab, Sender, {Name, mnesia_lib:val({?MODULE, Tab}), Sender}).

receive_done(_Alias, _Tab, _Sender, _State) ->
    ?DBG({done, _State}),
    ok.

close_table(Alias, Tab) ->
    sync_close_table(Alias, Tab).

sync_close_table(porset_copies, _Tab) ->
    ?DBG(_Tab).

fixtable(porset_copies, Tab, Bool) ->
    ?DBG({Tab, Bool}),
    ets:safe_fixtable(
        mnesia_lib:val({?MODULE, Tab}), Bool).

info(porset_copies, Tab, Type) ->
    ?DBG({Tab, Type}),
    Tid = mnesia_lib:val({?MODULE, Tab}),
    try ets:info(Tid, Type) of
        Val ->
            Val
    catch
        _:_ ->
            undefined
    end.

real_suffixes() ->
    [".dat"].

tmp_suffixes() ->
    [].

%% Index

index_is_consistent(_Alias, _Ix, _Bool) ->
    ok.  % Ignore for now

is_index_consistent(_Alias, _Ix) ->
    false.      % Always rebuild

%% Record operations

validate_record(_Alias, _Tab, RecName, Arity, Type, _Obj) ->
    {RecName, Arity, Type}.

validate_key(_Alias, _Tab, RecName, Arity, Type, _Key) ->
    {RecName, Arity, Type}.

-spec effect(storage(), mnesia:table(), tuple()) -> ok.
effect(Storage, Tab, Tup) ->
    case causal_compact(Storage, Tab, obj2ele(Tup)) of
        true ->
            dbg_out("not redundant, inserting ~p into ~p~n", [Tup, Tab]),
            mnesia_lib:db_put(Storage, Tab, Tup);
        false ->
            dbg_out("redundant", []),
            ok
    end.

db_put(Storage, Tab, {Obj, Ts}) ->
    dbg_out("running my own insert function and table ~p with val ~p and "
            "ts ~p~n",
            [Tab, Obj, Ts]),
    try
        Tup = add_meta(Obj, Ts, write),
        dbg_out("inserting ~p into ~p~n", [Tup, Tab]),
        effect(Storage, Tab, Tup)
    catch
        _:Reason ->
            warning("CRASH ~p ~p~n", [Reason, Tab])
    end.

db_get(Tab, Key) ->
    Res = mnesia_lib:db_get(Tab, Key),
    dbg_out("running my own lookup function on ~p, got ~p", [Tab, Res]),
    lists:filtermap(fun(Tup) ->
                       case tup_is_write(Tup) of
                           false -> false;
                           true -> {true, get_val_tup(Tup)}
                       end
                    end,
                    Res).

db_erase(Storage, Tab, {Obj, Ts}) ->
    dbg_out("running my own delete function and table ~p with val ~p and "
            "ts ~p~n",
            [Tab, Obj, Ts]),
    Tup = add_meta(Obj, Ts, delete),
    effect(Storage, Tab, Tup).

match_delete(porset_copies, Tab, Pat) ->
    ets:match_delete(
        mnesia_lib:val({?MODULE, Tab}), Pat).

db_first(Tab) ->
    dbg_out("running my own first function on ~p~n", [Tab]),
    mnesia_lib:db_first(Tab).

first(porset_copies, Tab) ->
    ets:first(
        mnesia_lib:val({?MODULE, Tab})).

last(Alias, Tab) ->
    first(Alias, Tab).

db_last_key(Tab) ->
    dbg_out("running my own last function on ~p~n", [Tab]),
    mnesia_lib:db_last(Tab).

db_next_key(Tab, Key) ->
    dbg_out("running my own next function on ~p", [Tab]),
    mnesia_lib:db_next_key(Tab, Key).

next(porset_copies, Tab, Key) ->
    ets:next(
        mnesia_lib:val({?MODULE, Tab}), Key).

db_prev(Tab, Key) ->
    dbg_out("running my own prev function on ~p", [Tab]),
    mnesia_lib:db_prev_key(Tab, Key).

prev(Alias, Tab, Key) ->
    next(Alias, Tab, Key).

slot(porset_copies, Tab, Pos) ->
    ets:slot(
        mnesia_lib:val({?MODULE, Tab}), Pos).

update_counter(porset_copies, Tab, C, Val) ->
    ets:update_counter(
        mnesia_lib:val({?MODULE, Tab}), C, Val).

db_select(Tab, Spec) ->
    Res = mnesia_lib:db_select(Tab, Spec),
    dbg_out("running my own select function on ~p with spec ~p got ~p", [Tab, Spec, Res]),
    Res.

select('$end_of_table' = End) ->
    End;
select({porset_copies, C}) ->
    ets:select(C).

select(Alias, Tab, Ms) ->
    Res = select(Alias, Tab, Ms, 100000),
    select_1(Res).

select_1('$end_of_table') ->
    [];
select_1({Acc, C}) ->
    case ets:select(C) of
        '$end_of_table' ->
            Acc;
        {New, Cont} ->
            select_1({New ++ Acc, Cont})
    end.

select(porset_copies, Tab, Ms, Limit) when is_integer(Limit); Limit =:= infinity ->
    ets:select(
        mnesia_lib:val({?MODULE, Tab}), Ms, Limit).

repair_continuation(Cont, Ms) ->
    ets:repair_continuation(Cont, Ms).

%%% pure op-based orset implementation

%% removes obsolete elements
%% @returns whether this element should be added
-spec causal_compact(storage(), mnesia:table(), element()) -> boolean().
causal_compact(Storage, Tab, Ele) ->
    ok = remove_obsolete(Storage, Tab, Ele),
    not redundant(Storage, Tab, Ele).

%% @doc checks whether the input element is redundant
%% i.e. if there are any other elements in the table that obsoletes this element
%% @end
-spec redundant(storage(), mnesia:table(), element()) -> boolean().
redundant(_Storage, _Tab, {_Ts, {delete, _Val}}) ->
    dbg_out("element is a delete, redundant", []),
    true;
redundant(Storage, Tab, Ele) ->
    dbg_out("checking redundancy", []),
    Key = get_val_key(get_val_ele(Ele)),
    Tups = mnesia_lib:db_get(Storage, Tab, Key),
    dbg_out("found ~p~n", [Tups]),
    Eles2 = lists:map(fun obj2ele/1, Tups),
    dbg_out("generated ~p~n", [Eles2]),
    lists:any(fun(Ele2) -> obsolete(Ele, Ele2) end, Eles2).

% check_redundant(_Tab, '$end_of_table', _E) ->
%     dbg_out("element ~p is not redundant", [_E]),
%     false;
% check_redundant(Tab, Key, Ele1) ->
%     NextKey = next(porset_copies, Tab, Key),
%     % guaranteed to return a value since we are iterating over all keys
%     Tups =
%         ets:lookup(
%             mnesia_lib:val({?MODULE, Tab}), Key),
%     dbg_out("found ~p~n", [Tups]),
%     Eles2 = lists:map(fun obj2ele/1, Tups),
%     dbg_out("generated ~p~n", [Eles2]),
%     lists:any(fun(Ele2) -> obsolete(Ele1, Ele2) end, Eles2)
%     orelse check_redundant(Tab, NextKey, Ele1).

% TODO there might be better ways of doing the scan
%% removes elements that are obsoleted by Ele
%% When we check for elements obsoleted by Ele, we only care about those with
%% the same key as Ele, no need to go through the entire table
-spec remove_obsolete(storage(), mnesia:table(), element()) -> ok.
remove_obsolete(Storage, Tab, Ele) ->
    dbg_out("checking obsolete", []),
    Key = get_val_key(get_val_ele(Ele)),
    dbg_out("key ~p~n", [Key]),
    Tups = mnesia_lib:db_get(Storage, Tab, Key),
    dbg_out("existing tuples ~p~n", [Tups]),
    mnesia_lib:db_erase(Storage, Tab, Key),
    Keep = lists:filter(fun(Tup) -> not obsolete(obj2ele(Tup), Ele) end, Tups),
    dbg_out("removed obsolete ~p kept ~p~n", [Tups -- Keep, Keep]),
    mnesia_lib:db_put(Storage, Tab, Keep),
    ok.

    % do_remove_obsolete(Tab, first(porset_copies, Tab), Ele).

% -spec do_remove_obsolete(mnesia:table(), term(), element()) -> ok.
% do_remove_obsolete(_Tab, '$end_of_table', _E) ->
%     dbg_out("done removing obsolete"),
%     ok;
% do_remove_obsolete(Tab, Key, Ele2) ->
%     NextKey = next(porset_copies, Tab, Key),
%     % it's possible to have mutliple tuples since the store is keyed by ts
%     Tups =
%         ets:lookup(
%             mnesia_lib:val({?MODULE, Tab}), Key),
%     dbg_out("found ~p~n", [Tups]),
%     Eles1 = lists:map(fun obj2ele/1, Tups),
%     dbg_out("generated ~p, input ele ~p~n", [Eles1, Ele2]),
%     Keep =
%         lists:filtermap(fun(Ele1) ->
%                            case obsolete(Ele1, Ele2) of
%                                true -> false;
%                                false -> {true, ele2obj(Ele1)}
%                            end
%                         end,
%                         Eles1),
%     dbg_out("removed obsolete ~p kept ~p~n", [Tups -- Keep, Keep]),
%     ets:delete(
%         mnesia_lib:val({?MODULE, Tab}), Key),
%     ets:insert(
%         mnesia_lib:val({?MODULE, Tab}), Keep),
%     do_remove_obsolete(Tab, NextKey, Ele2).

%%% Helper

key_pos() ->
    2.

-spec obj2ele(tuple()) -> element().
obj2ele(Obj) ->
    {get_ts(Obj), {get_op(Obj), get_val_tup(Obj)}}.

ele2obj({Ts, {Op, Val}}) ->
    add_meta(Val, Ts, Op).

get_val_ele({_Ts, {_Op, V}}) ->
    V.

%% @equiv delete_meta/1
get_val_tup(Obj) ->
    delete_meta(Obj).

%% @returns true if second element obsoletes the first one
-spec obsolete({ts(), {op(), val()}}, {ts(), {op(), val()}}) -> boolean().
obsolete({Ts1, {write, V1}}, {Ts2, {write, V2}}) ->
    equals(V1, V2) andalso mnesia_causal:compare_vclock(Ts1, Ts2) =:= lt;
obsolete({Ts1, {write, V1}}, {Ts2, {delete, V2}}) ->
    dbg_out("equals ~p~n", [equals(V1, V2)]),
    dbg_out("vclock V1~p V2~p ~p~n", [V1, V2, mnesia_causal:compare_vclock(Ts1, Ts2)]),
    equals(V1, V2) andalso mnesia_causal:compare_vclock(Ts1, Ts2) =:= lt;
obsolete({_Ts1, {delete, _V1}}, _X) ->
    true.

-spec equals(tuple(), tuple()) -> boolean().
equals(V1, V2) ->
    element(key_pos(), V1) =:= element(key_pos(), V2).

-spec get_val_key(tuple()) -> term().
get_val_key(V) ->
    element(key_pos(), V).

-spec add_ts(tuple(), ts()) -> tuple().
add_ts(Obj, Ts) ->
    erlang:append_element(Obj, Ts).

add_op(Obj, Op) ->
    erlang:append_element(Obj, Op).

get_op(Obj) ->
    element(tuple_size(Obj), Obj).

get_ts(Obj) ->
    element(tuple_size(Obj) - 1, Obj).

-spec add_meta(tuple(), ts(), op()) -> tuple().
add_meta(Obj, Ts, Op) ->
    add_op(add_ts(Obj, Ts), Op).

-spec delete_meta(tuple()) -> tuple().
delete_meta(Obj) ->
    Last = tuple_size(Obj),
    erlang:delete_element(Last - 1, erlang:delete_element(Last, Obj)).

tup_is_write(Tup) ->
    get_op(Tup) =:= write.
