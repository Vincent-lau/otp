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

-include("mnesia.hrl").

-export([db_put/3, db_erase/3, db_get/2, db_first/1, db_last_key/1, db_next_key/2,
         db_select/2, db_prev/2, db_all_keys/1]).
-export([mktab/2, unsafe_mktab/2]).

-type op() :: write | delete.
-type val() :: any().
-type ts() :: mnesia_causal:vclock().
-type element() :: {ts(), {op(), val()}}.
-type storage() :: ram_copies | disk_copies | disc_only_copies | {ext, atom(), atom()}.

-import(mnesia_lib, [important/2, dbg_out/2, verbose/2, warning/2]).

-compile([nowarn_unused_function]).

val(Var) ->
    case ?catch_val_and_stack(Var) of
        {'EXIT', Stacktrace} ->
            mnesia_lib:other_val(Var, Stacktrace);
        Value ->
            Value
    end.

mktab(Tab, [{keypos, 2}, public, named_table, Type | EtsOpts])
    when Type =:= porset orelse Type =:= porbag ->
    Args1 = [{keypos, 2}, public, named_table, bag | EtsOpts],
    {Tab1, _Tab2} = porset_name(Tab),
    mnesia_monitor:mktab(Tab1, Args1).

unsafe_mktab(Tab, [{keypos, 2}, public, named_table, Type | EtsOpts])
    when Type =:= porset orelse Type =:= porbag ->
    Args1 = [{keypos, 2}, public, named_table, bag | EtsOpts],
    {Tab1, _Tab2} = porset_name(Tab),
    mnesia_monitor:unsafe_mktab(Tab1, Args1).

porset_name(Tab) ->
    {list_to_atom(atom_to_list(Tab)), list_to_atom(atom_to_list(Tab) ++ "_tlog")}.

-spec effect(storage(), mnesia:table(), tuple()) -> ok.
effect(Storage, Tab, Tup) ->
    case causal_compact(Storage, Tab, obj2ele(Tup)) of
        true ->
            dbg_out("not redundant, inserting ~p into ~p~n", [Tup, Tab]),
            mnesia_lib:db_put(Storage, Tab, Tup),
            ok;
        false ->
            dbg_out("redundant", []),
            ok
    end.

db_all_keys(Tab) when is_atom(Tab), Tab /= schema ->
    Pat0 = val({Tab, wild_pattern}),
    Pat1 =
        erlang:append_element(
            erlang:append_element(Pat0, '_'), write),
    Pat = setelement(2, Pat1, '$1'),
    Keys = db_select(Tab, [{Pat, [], ['$1']}]),
    case val({Tab, setorbag}) of
        porbag ->
            mnesia_lib:uniq(Keys);
        porset ->
            Keys;
        Other ->
            error({incorrect_ec_table_type, Other})
    end.

db_put(Storage, Tab, Obj) when is_map(element(tuple_size(Obj), Obj)) ->
    maybe_create_index(Tab, tuple_size(Obj) + 1),
    Ts = element(tuple_size(Obj), Obj),
    dbg_out("running my own insert function and table ~p with val ~p and "
            "ts ~p~n",
            [Tab, Obj, Ts]),
    try
        Tup = add_op(Obj, write),
        dbg_out("inserting ~p into ~p~n", [Tup, Tab]),
        effect(Storage, Tab, Tup)
    catch
        _:Reason ->
            warning("CRASH ~p ~p~n", [Reason, Tab])
    end;
db_put(_S, _T, Obj) ->
    error("bad tuple ~p, no ts at the end~n", [Obj]).

% TODO this might impact performance
maybe_create_index(Tab, Index) ->
    Indices = val({Tab, index}),
    case lists:member(Index, Indices) of
        true ->
            ok;
        false ->
            mnesia:add_table_index(Tab, Index)
    end.

db_get(Tab, Key) ->
    Res = mnesia_lib:db_get(Tab, Key),
    Res2 =
        lists:filtermap(fun(Tup) ->
                           case tup_is_write(Tup) of
                               false -> false;
                               true -> {true, get_val_tup(Tup)}
                           end
                        end,
                        Res),
    dbg_out("running my own lookup function on ~p, got ~p~n", [Tab, Res2]),
    case val({Tab, setorbag}) of
        porset ->
            Res3 = mnesia_lib:uniq(Res2),
            resolve_cc_add(Res3);
        porbag ->
            Res2;
        Other ->
            error({bad_val, Other})
    end.

-spec resolve_cc_add([element()]) -> [element()].
resolve_cc_add(Res) when length(Res) =< 1 ->
    Res;
resolve_cc_add(Res) ->
    dbg_out("selecting minimum element from ~p to resolve concurrent addition~n", [Res]),
    [lists:min(Res)].

db_erase(Storage, Tab, Obj) when is_map(element(tuple_size(Obj), Obj)) ->
    Ts = element(tuple_size(Obj), Obj),
    dbg_out("running my own delete function and table ~p with val ~p and "
            "ts ~p~n",
            [Tab, Obj, Ts]),
    Tup = add_op(Obj, delete),
    effect(Storage, Tab, Tup);
db_erase(_S, _T, Obj) ->
    error("bad tuple ~p, no ts at the end~n", [Obj]).

db_match_erase(Storage, Tab, Pat) ->
    dbg_out("running my own match delete function on ~p~n", [Tab]),
    case val({Tab, setorbag}) of
        porset ->
            mnesia_lib:db_match_delete(Storage, Tab, Pat);
        porbag ->
            mnesia_lib:db_match_delete(Storage, Tab, Pat);
        Other ->
            error({bad_val, Other})
    end.

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
    {Pid1, Mref1} =
        spawn_monitor(fun() ->
                         remove_obsolete(Storage, Tab, Ele),
                         dbg_out("sending message to ~p~n", [whereis(waiter)]),
                         receive {Parent, Mref} -> Parent ! {Mref, {obsolete, ok}} end
                      end),
    {Pid2, Mref2} =
        spawn_monitor(fun() ->
                         Red = redundant(Storage, Tab, Ele),
                         receive {Parent, Mref} -> Parent ! {Mref, {redundancy, Red}} end
                      end),
    Parent = self(),
    Pid1 ! {Parent, Mref1},
    Pid2 ! {Parent, Mref2},
    Red1 = wait_causal_compact(Mref1),
    Red2 = wait_causal_compact(Mref2),
    Red1 andalso Red2.

    % ok = remove_obsolete(Storage, Tab, Ele),
    % not redundant(Storage, Tab, Ele).

wait_causal_compact(Mref) ->
    receive
        {Mref, {obsolete, ok}} ->
            erlang:demonitor(Mref, [flush]),
            dbg_out("obsolete removed ~n", []),
            true;
        {Mref, {redundancy, Red}} ->
            erlang:demonitor(Mref, [flush]),
            dbg_out("redundant ~p~n", [Red]),
            not Red;
        {'DOWN', Mref, _, _, Reason} ->
            {error, Reason}
    end.

%% @doc checks whether the input element is redundant
%% i.e. if there are any other elements in the table that obsoletes this element
%% @end
-spec redundant(storage(), mnesia:table(), element()) -> boolean().
redundant(_Storage, _Tab, {_Ts, {delete, _Val}}) ->
    dbg_out("element is a delete, redundant", []),
    true;
redundant(Storage, Tab, Ele) ->
    dbg_out("checking redundancy~n", []),
    Key = get_val_key(get_val_ele(Ele)),
    Tups = mnesia_lib:db_get(Storage, Tab, Key),
    dbg_out("found ~p~n", [Tups]),
    Eles2 = lists:map(fun obj2ele/1, Tups),
    dbg_out("generated ~p~n", [Eles2]),
    lists:any(fun(Ele2) -> obsolete(Tab, Ele, Ele2) end, Eles2).

% TODO there might be better ways of doing the scan
%% removes elements that are obsoleted by Ele
%% When we check for elements obsoleted by Ele, we only care about those with
%% the same key as Ele, no need to go through the entire table
-spec remove_obsolete(storage(), mnesia:table(), element()) -> ok.
remove_obsolete(Storage, Tab, Ele) ->
    dbg_out("checking obsolete~n", []),
    Key = get_val_key(get_val_ele(Ele)),
    % dbg_out("key ~p~n", [Key]),
    Tups = mnesia_lib:db_get(Storage, Tab, Key),
    % dbg_out("existing tuples ~p~n", [Tups]),
    Keep = lists:filter(fun(Tup) -> not obsolete(Tab, obj2ele(Tup), Ele) end, Tups),
    % dbg_out("removed obsolete ~p kept ~p~n", [Tups -- Keep, Keep]),
    mnesia_lib:db_erase(Storage, Tab, Key),
    mnesia_lib:db_put(Storage, Tab, Keep),
    ok.

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
-spec obsolete(mnesia:table(), {ts(), {op(), val()}}, {ts(), {op(), val()}}) -> boolean().
obsolete(Tab, {Ts1, {write, V1}}, {Ts2, {write, V2}}) ->
    equals(Tab, V1, V2) andalso mnesia_causal:compare_vclock(Ts1, Ts2) =:= lt;
obsolete(Tab, {Ts1, {write, V1}}, {Ts2, {delete, V2}}) ->
    equals(Tab, V1, V2) andalso mnesia_causal:compare_vclock(Ts1, Ts2) =:= lt;
obsolete(_Tab, {_Ts1, {delete, _V1}}, _X) ->
    true.

-spec equals(mnesia:table(), tuple(), tuple()) -> boolean().
equals(Tab, V1, V2) ->
    case val({Tab, setorbag}) of
        porset ->
            element(key_pos(), V1) =:= element(key_pos(), V2);
        porbag ->
            V1 =:= V2;
        Other ->
            error({bad_val, Other})
    end.

-spec get_val_key(tuple()) -> term().
get_val_key(V) ->
    element(key_pos(), V).

-spec add_ts(tuple(), ts()) -> tuple().
add_ts(Obj, Ts) ->
    erlang:append_element(Obj, Ts).

% @doc this changes the tuple with the last element as the ts to the key
% by {key, ts}, and the last element is now the key, which will be the index
-spec transform_key(tuple()) -> tuple().
transform_key(Obj) when is_map(element(tuple_size(Obj), Obj)) ->
    K = erlang:element(key_pos(), Obj),
    Ts = erlang:element(tuple_size(Obj), Obj),
    O2 = setelement(key_pos(), Obj, {K, Ts}),
    setelement(tuple_size(O2), Obj, K).

-spec add_op(tuple(), op()) -> tuple().
transform_meta(Obj, Op) ->
    add_op(transform_key(Obj), Op).

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
