-module(mnesia_pawset).

-include("mnesia.hrl").

-export([db_put/3, db_erase/3, db_get/2, db_first/1, db_last/1, db_next_key/2,
         db_select/2, db_prev_key/2, db_all_keys/1, db_match_erase/3]).
-export([mktab/2, unsafe_mktab/2]).
-export([remote_match_object/2]).
-export([spawn_stabiliser/0]).
-export([reify/3]).

-type op() :: write | delete.
-type val() :: any().
-type ts() :: mnesia_causal:vclock().
-type element() :: {ts(), {op(), val()}}.
-type storage() :: ram_copies | disk_copies | disc_only_copies | {ext, atom(), atom()}.

-import(mnesia_lib, [important/2, dbg_out/2, verbose/2, warning/2]).

stabiliser_interval() ->
    1000000.

val(Var) ->
    case ?catch_val_and_stack(Var) of
        {'EXIT', Stacktrace} ->
            mnesia_lib:other_val(Var, Stacktrace);
        Value ->
            Value
    end.

mktab(Tab, [{keypos, 2}, public, named_table, Type | EtsOpts])
    when Type =:= pawset orelse Type =:= pawbag ->
    Args1 = [{keypos, 2}, public, named_table, bag | EtsOpts],
    {Tab1, _Tab2} = pawset_name(Tab),
    mnesia_monitor:mktab(Tab1, Args1).

unsafe_mktab(Tab, [{keypos, 2}, public, named_table, Type | EtsOpts])
    when Type =:= pawset orelse Type =:= pawbag ->
    Args1 = [{keypos, 2}, public, named_table, bag | EtsOpts],
    {Tab1, _Tab2} = pawset_name(Tab),
    mnesia_monitor:unsafe_mktab(Tab1, Args1).

pawset_name(Tab) ->
    {list_to_atom(atom_to_list(Tab)), list_to_atom(atom_to_list(Tab) ++ "_s")}.

%%==================== writes ====================

-spec effect(storage(), mnesia:table(), tuple()) -> ok.
effect(Storage, Tab, Tup) ->
    case causal_compact(Storage, Tab, obj2ele(Tup)) of
        true ->
            dbg_out("not redundant, inserting ~p into ~p~n", [Tup, Tab]),
            mnesia_lib:db_put(Storage, Tab, remove_op(Tup)),
            ok;
        false ->
            dbg_out("redundant", []),
            ok
    end.

db_put(Storage, Tab, Obj) when is_map(element(tuple_size(Obj), Obj)) ->
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

db_erase(Storage, Tab, Obj) when is_map(element(tuple_size(Obj), Obj)) ->
    Ts = element(tuple_size(Obj), Obj),
    dbg_out("running my own delete function and table ~p with val ~p and "
            "ts ~p~n",
            [Tab, Obj, Ts]),
    Tup = add_op(Obj, delete),
    effect(Storage, Tab, Tup);
db_erase(_S, _T, Obj) ->
    error("bad tuple ~p, no ts at the end~n", [Obj]).

% used for delete_object, hence pattern cannot be a pattern
db_match_erase(Storage, Tab, Pat) ->
    dbg_out("running my own match delete function on ~p~n", [Tab]),
    db_erase(Storage, Tab, Pat).

%%==================== reads ====================

db_get(Tab, Key) ->
    Tups = mnesia_lib:db_get(Tab, Key),
    Res = [remove_ts(Tup) || Tup <- Tups],
    dbg_out("running my own lookup function on ~p, got ~p~n", [Tab, Res]),
    uniq(Tab, Res).

db_all_keys(Tab) when is_atom(Tab), Tab /= schema ->
    Pat0 = val({Tab, wild_pattern}),
    Pat = setelement(2, Pat0, '$1'),
    Keys = db_select(Tab, [{Pat, [], ['$1']}]),
    case val({Tab, setorbag}) of
        pawbag ->
            mnesia_lib:uniq(Keys);
        pawset ->
            Keys;
        Other ->
            error({incorrect_ec_table_type, Other})
    end.

db_match_object(Tab, Pat0) ->
    dbg_out("running my own match object function on ~p~n", [Tab]),
    Pat = wild_ts(Pat0),
    Res = mnesia_lib:db_match_object(Tab, Pat),
    case val({Tab, setorbag}) of
        pawset ->
            Res1 = [remove_ts(Tup) || Tup <- Res],
            uniq(Tab, Res1);
        pawbag ->
            [remove_ts(Tup) || Tup <- Res];
        Other ->
            error({bad_val, Other})
    end.

db_first(Tab) ->
    dbg_out("running my own first function on ~p~n", [Tab]),
    mnesia_lib:db_first(Tab).

db_last(Tab) ->
    dbg_out("running my own last function on ~p~n", [Tab]),
    mnesia_lib:db_last(Tab).

db_next_key(Tab, Key) ->
    dbg_out("running my own next function on ~p", [Tab]),
    mnesia_lib:db_next_key(Tab, Key).

db_prev_key(Tab, Key) ->
    dbg_out("running my own prev function on ~p", [Tab]),
    mnesia_lib:db_prev_key(Tab, Key).

db_select(Tab, Spec) ->
    Spec1 = [{wild_ts(MatchHead), Guards, Results} || {MatchHead, Guards, Results} <- Spec],
    Res = mnesia_lib:db_select(Tab, Spec1),
    dbg_out("running my own select function on ~p with spec ~p got ~p", [Tab, Spec, Res]),
    Res.

uniq(Tab, Res) ->
    case val({Tab, setorbag}) of
        pawset ->
            Res1 = mnesia_lib:uniq(Res),
            resolve_cc_add(Res1);
        pawbag ->
            Res;
        Other ->
            error({bad_val, Other})
    end.

-spec resolve_cc_add([element()]) -> [element()].
resolve_cc_add(Res) when length(Res) =< 1 ->
    Res;
resolve_cc_add(Res) ->
    dbg_out("selecting minimum element from ~p to resolve concurrent addition~n", [Res]),
    [lists:min(Res)].

remote_match_object(Tab, Pat) ->
    Key = element(2, Pat),
    case mnesia:has_var(Key) of
        false ->
            db_match_object(Tab, Pat);
        true ->
            PosList = regular_indexes(Tab),
            remote_match_object(Tab, Pat, PosList)
    end.

remote_match_object(Tab, Pat, [Pos | Tail]) when Pos =< tuple_size(Pat) ->
    IxKey = element(Pos, Pat),
    case mnesia:has_var(IxKey) of
        false ->
            % TODO maybe a good idea to do filtermap afterwards
            % benchmark to see
            Pat1 = wild_ts(Pat),
            mnesia_index:dirty_match_object(Tab, Pat1, Pos);
        true ->
            remote_match_object(Tab, Pat, Tail)
    end;
remote_match_object(Tab, Pat, []) ->
    db_match_object(Tab, Pat);
remote_match_object(Tab, Pat, _PosList) ->
    mnesia:abort({bad_type, Tab, Pat}).

regular_indexes(Tab) ->
    PosList = val({Tab, index}),
    [P || P <- PosList, is_integer(P)].

%%% ==========pure op-based awset implementation==========

-spec reify(storage(), mnesia:table(), element()) -> ok.
reify(Storage, Tab, Ele) ->
    io:format("reifying ~p~n", [Ele]),
    remove_obsolete(Storage, Tab, Ele).

%% @returns whether this element should be added
-spec causal_compact(storage(), mnesia:table(), element()) -> boolean().
causal_compact(Storage, Tab, Ele) ->
    {Pid1, Mref1} =
        spawn_monitor(fun() ->
                         remove_obsolete(Storage, Tab, Ele),
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
    dbg_out("element is a delete, redundant~n", []),
    true;
redundant(Storage, Tab, Ele) ->
    dbg_out("checking redundancy~n", []),
    Key = get_val_key(get_val_ele(Ele)),
    Tups = [add_op(Tup, write) || Tup <- mnesia_lib:db_get(Storage, Tab, Key)],
    dbg_out("found ~p~n", [Tups]),
    Eles2 = lists:map(fun obj2ele/1, Tups),
    dbg_out("generated ~p~n", [Eles2]),
    lists:any(fun(Ele2) -> obsolete(Tab, Ele, Ele2) end, Eles2).

%% @edoc removes elements that are obsoleted by Ele
-spec remove_obsolete(storage(), mnesia:table(), element()) -> ok.
remove_obsolete(Storage, Tab, Ele) ->
    Key = get_val_key(get_val_ele(Ele)),
    case mnesia_lib:db_get(Storage, Tab, Key) of
        [] ->
            ok;
        Tups when length(Tups) > 0 ->
            Tups2 = [add_op(Tup, write) || Tup <- Tups],
            Keep = lists:filter(fun(Tup) -> not obsolete(Tab, obj2ele(Tup), Ele) end, Tups2),
            Keep2 = [remove_op(Tup) || Tup <- Keep],
            mnesia_lib:db_erase(Storage, Tab, Key),
            mnesia_lib:db_put(Storage, Tab, Keep2),
            ok
    end.

spawn_stabiliser() ->
    {Pid, Ref} = spawn_monitor(fun() -> causal_stabiliser([]) end),
    ok = mnesia_causal:register_stabiliser(Pid),
    erlang:send_after(stabiliser_interval(), Pid, stabilise),
    {Pid, Ref}.

causal_stabiliser(AccTs) ->
    receive
        {stable_ts, Ts} ->
            causal_stabiliser([Ts | AccTs]);
        stabilise ->
            % TODO checking all tables not might be a good way
            Tables = mnesia:system_info(tables),
            pawsets =
                lists:filter(fun(Tab) ->
                                Type = mnesia_monitor:get_env({Tab, setorbag}),
                                Type =:= pawset orelse Type =:= pawbag
                             end,
                             Tables),
            lists:foreach(fun(Tab) -> stablise(Tab, AccTs) end, pawsets),
            erlang:send_after(stabiliser_interval(), self(), stabilise),
            causal_stabiliser([]);
        Unexpected ->
            error({unexpected, Unexpected})
    end.

stablise(_Tab, []) ->
    dbg_out("no stable time~n", []),
    ok;
stablise(Tab, [T | Ts]) ->
    case find_by_ts(Tab, T) of
        [] ->
            ok;
        Tuples ->
            io:format("stablising ~p with ts ~p~n", [Tuples, T]),
            Res2 = [set_ts(Tup, mnesia_causal:bot(), tuple_size(Tup)) || Tup <- Tuples],
            mnesia_lib:db_put(Tab, Res2),
            [mnesia_lib:db_erase(Tab, element(key_pos(), Tup)) || Tup <- Tuples]
    end,
    stablise(Tab, Ts).

% -spec stablise(tuple()) -> {boolean(), tuple()}.
% stablise(Tups) ->
%     lists:foldl(fun(Tup, {HasStable, Res}) ->
%                    Ts = get_ts(Tup),
%                    case not mnesia_causal:is_bot(Ts) andalso mnesia_causal:tcstable(Ts) of
%                        true -> {true, [set_ts(Tup, mnesia_causal:bot()) | Res]};
%                        false -> {HasStable, [Tup | Res]}
%                    end
%                 end,
%                 {false, []},
%                 Tups).

-spec find_by_ts(mnesia:table(), ts()) -> [tuple()].
find_by_ts(Tab, Ts) ->
    Pat = val({Tab, wild_pattern}),
    Pat2 = erlang:append_element(Pat, Ts),
    Pat3 = erlang:append_element(Pat2, '_'),
    db_select(Tab, [{Pat3, [], [Ts]}]).

key_pos() ->
    2.

-spec obj2ele(tuple()) -> element().
obj2ele(Obj) ->
    {get_ts(Obj), {get_op(Obj), get_val_tup(Obj)}}.

% ele2obj({Ts, {Op, Val}}) ->
%     add_meta(Val, Ts, Op).

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
        pawset ->
            element(key_pos(), V1) =:= element(key_pos(), V2);
        pawbag ->
            V1 =:= V2;
        Other ->
            error({bad_val, Other})
    end.

-spec get_val_key(tuple()) -> term().
get_val_key(V) ->
    element(key_pos(), V).

% -spec add_ts(tuple(), ts()) -> tuple().
% add_ts(Obj, Ts) ->
%     erlang:append_element(Obj, Ts).

% @doc this changes the tuple whose last element is the timestamp to the key
% by {key, ts}, and the last element is now the key, which will be the index
% -spec transform_key(tuple()) -> tuple().
% transform_key(Obj) when is_map(element(tuple_size(Obj), Obj)) ->
%     K = erlang:element(key_pos(), Obj),
%     Ts = erlang:element(tuple_size(Obj), Obj),
%     O2 = setelement(key_pos(), Obj, {K, Ts}),
%     setelement(tuple_size(O2), Obj, K).

% -spec add_op(tuple(), op()) -> tuple().
% transform_meta(Obj, Op) ->
%     add_op(transform_key(Obj), Op).

add_op(Obj, Op) ->
    erlang:append_element(Obj, Op).

remove_op(Obj) ->
    erlang:delete_element(tuple_size(Obj), Obj).

get_op(Obj) ->
    element(tuple_size(Obj), Obj).

get_ts(Obj) ->
    element(tuple_size(Obj) - 1, Obj).

% set_ts(Obj, Ts) ->
%     setelement(tuple_size(Obj) - 1, Obj, Ts).

set_ts(Obj, Ts, Idx) ->
    setelement(Idx, Obj, Ts).

remove_ts(Obj) ->
    erlang:delete_element(tuple_size(Obj), Obj).

-spec delete_meta(tuple()) -> tuple().
delete_meta(Obj) ->
    Last = tuple_size(Obj),
    erlang:delete_element(Last - 1, erlang:delete_element(Last, Obj)).

wild_ts(Pat) ->
    erlang:append_element(Pat, '_').
