-module(mnesia_prwset).

-include("mnesia.hrl").

-export([db_put/3, db_erase/3, db_get/2, db_first/1, db_last/1, db_next_key/2,
         db_select/2, db_prev_key/2, db_all_keys/1, db_match_erase/3]).
-export([mktab/2, unsafe_mktab/2]).
-export([remote_match_object/2]).
-export([spawn_stabiliser/1]).
-export([reify/3]).

-type op() :: write | delete.
-type val() :: any().
-type ts() :: mnesia_causal:vclock().
-type element() :: {ts(), {op(), val()}}.
-type storage() :: ram_copies | disk_copies | disc_only_copies | {ext, atom(), atom()}.

-import(mnesia_lib, [important/2, dbg_out/2, verbose/2, warning/2]).

stabiliser_interval() ->
    1000.

val(Var) ->
    case ?catch_val_and_stack(Var) of
        {'EXIT', Stacktrace} ->
            mnesia_lib:other_val(Var, Stacktrace);
        Value ->
            Value
    end.

mktab(Tab, [{keypos, 2}, public, named_table, Type | EtsOpts])
    when Type =:= prwset orelse Type =:= prwbag ->
    Args1 = [{keypos, 2}, public, named_table, bag | EtsOpts],
    {Tab1, _Tab2} = prwset_name(Tab),
    notify_stabiliser({add_table, Tab1}),
    mnesia_monitor:mktab(Tab1, Args1).

unsafe_mktab(Tab, [{keypos, 2}, public, named_table, Type | EtsOpts])
    when Type =:= prwset orelse Type =:= prwbag ->
    Args1 = [{keypos, 2}, public, named_table, bag | EtsOpts],
    {Tab1, _Tab2} = prwset_name(Tab),
    notify_stabiliser({add_table, Tab1}),
    mnesia_monitor:unsafe_mktab(Tab1, Args1).

prwset_name(Tab) ->
    {list_to_atom(atom_to_list(Tab)), list_to_atom(atom_to_list(Tab) ++ "_s")}.

%%==================== writes ====================

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
    Tups2 = remove_wins(Tab, Tups),
    dbg_out("running my own lookup function on ~p, got ~p before removing "
            "metadata~n",
            [Tab, Tups2]),
    Res = [get_val_tup(Tup) || Tup <- Tups2],
    dbg_out("running my own lookup function on ~p, got ~p~n", [Tab, Res]),
    uniq(Tab, Res).

-spec remove_wins(mnesia:table(), [tuple()]) -> [tuple()].
remove_wins(Tab, Tups) ->
    Rmvs = lists:filter(fun(Tup) -> get_op(Tup) =:= delete end, Tups),
    NoneInRmv =
        fun(Tup) ->
           lists:all(fun(Rmv) -> not equals(Tab, get_val_tup(Tup), get_val_tup(Rmv)) end, Rmvs)
        end,
    lists:filter(fun(Tup) ->
                    case get_op(Tup) of
                        delete -> false;
                        write -> NoneInRmv(Tup)
                    end
                 end,
                 Tups).

db_all_keys(Tab) when is_atom(Tab), Tab /= schema ->
    Pat0 = val({Tab, wild_pattern}),
    Pat = setelement(2, Pat0, '$1'),
    Keys = db_select(Tab, [{Pat, [], ['$1']}]),
    case val({Tab, setorbag}) of
        prwbag ->
            mnesia_lib:uniq(Keys);
        prwset ->
            Keys;
        Other ->
            error({incorrect_ec_table_type, Other})
    end.

db_match_object(Tab, Pat0) ->
    dbg_out("running my own match object function on ~p~n", [Tab]),
    Pat = wild_ts_op(Pat0),
    Res = mnesia_lib:db_match_object(Tab, Pat),
    Res2 = remove_wins(Tab, Res),
    case val({Tab, setorbag}) of
        prwset ->
            Res3 = [get_val_tup(Tup) || Tup <- Res2],
            uniq(Tab, Res3);
        prwbag ->
            [get_val_tup(Tup) || Tup <- Res2];
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
    Spec1 =
        [{wild_ts_op(MatchHead), Guards, Results} || {MatchHead, Guards, Results} <- Spec],
    Res = mnesia_lib:db_select(Tab, Spec1),
    Res2 = remove_wins(Tab, Res),
    dbg_out("running my own select function on ~p with spec ~p got ~p", [Tab, Spec, Res2]),
    Res2.

uniq(Tab, Res) ->
    case val({Tab, setorbag}) of
        prwset ->
            Res1 = mnesia_lib:uniq(Res),
            resolve_cc_add(Res1);
        prwbag ->
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
            Pat1 = wild_ts_op(Pat),
            Tups = mnesia_index:dirty_match_object(Tab, Pat1, Pos),
            remove_wins(Tab, Tups);
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

%%% ==========pure op-based rwset implementation==========

-spec reify(storage(), mnesia:table(), element()) -> ok.
reify(Storage, Tab, Ele) ->
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
redundant(Storage, Tab, Ele) ->
    dbg_out("checking redundancy~n", []),
    Key = get_val_key(Tab, get_val_ele(Ele)),
    Tups = [Tup || Tup <- mnesia_lib:db_get(Storage, Tab, Key)],
    dbg_out("found ~p~n", [Tups]),
    Eles2 = lists:map(fun obj2ele/1, Tups),
    dbg_out("generated ~p~n", [Eles2]),
    lists:any(fun(Ele2) -> obsolete(Tab, Ele, Ele2) end, Eles2).

%% @edoc removes elements that are obsoleted by Ele
-spec remove_obsolete(storage(), mnesia:table(), element()) -> ok.
remove_obsolete(Storage, Tab, Ele) ->
    Key = get_val_key(Tab, get_val_ele(Ele)),
    case mnesia_lib:db_get(Storage, Tab, Key) of
        [] ->
            ok;
        Tups when length(Tups) > 0 ->
            Tups2 = [Tup || Tup <- Tups],
            Keep = lists:filter(fun(Tup) -> not obsolete(Tab, obj2ele(Tup), Ele) end, Tups2),
            Keep2 = [Tup || Tup <- Keep],
            mnesia_lib:db_erase(Storage, Tab, Key),
            mnesia_lib:db_put(Storage, Tab, Keep2),
            ok
    end.

spawn_stabiliser(no) ->
    {undefined, undefine};
spawn_stabiliser(yes) ->
    {Pid, Ref} = spawn_monitor(fun() -> causal_stabiliser([], []) end),
    register(?MODULE, Pid),
    ok = mnesia_causal:reg_stabiliser(Pid),
    erlang:send_after(stabiliser_interval(), Pid, stabilise),
    {Pid, Ref}.

notify_stabiliser(Msg) ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        Pid ->
            Pid ! Msg
    end.

causal_stabiliser(Tabs, Ts) ->
    receive
        stabilise ->
            case node() of
                'bench2@vincent-pc' ->
                    io:format("stabilising ~p~n", [Ts]);
                _ ->
                    ok
            end,
            [stabilise(Tab, Ts) || Tab <- Tabs],
            erlang:send_after(stabiliser_interval(), self(), stabilise),
            causal_stabiliser(Tabs, []);
        {add_timestamp, T} ->
            Ts2 = lists:foldl(fun(T1, AccIn) ->
                                 case mnesia_causal:vclock_leq(T1, T) of
                                     true -> AccIn;
                                     false -> [T1 | AccIn]
                                 end
                              end,
                              [],
                              Ts),
            causal_stabiliser(Tabs, [T | Ts2]);
        {add_table, Tab} ->
            causal_stabiliser([Tab | Tabs], Ts);
        Unexpected ->
            error({unexpected, Unexpected})
    end.

stabilise(Tab, Ts) ->
    mnesia_lib:db_fixtable(val({Tab, storage_type}), Tab, true),
    do_stabilise(Tab, Ts, mnesia_lib:db_first(Tab)),
    mnesia_lib:db_fixtable(val({Tab, storage_type}), Tab, false).

do_stabilise(_Tab, _Ts, '$end_of_table') ->
    ok;
do_stabilise(Tab, Ts, Key) ->
    Tups = mnesia_lib:db_get(Tab, Key),
    Tups2 =
        lists:map(fun(Tup) ->
                     T1 = get_ts(tuple_size(Tup), Tup),
                     case lists:any(fun(T) -> mnesia_causal:vclock_leq(T1, T) end, Ts) of
                         true -> set_ts(Tup, mnesia_causal:bot(), tuple_size(Tup));
                         false -> Tup
                     end
                  end,
                  Tups),
    NextKey = mnesia_lib:db_next_key(Tab, Key),
    mnesia_lib:db_erase(Tab, Key),
    mnesia_lib:db_put(Tab, Tups2),
    do_stabilise(Tab, Ts, NextKey).

key_pos(Tab) ->
    case val({Tab, storage_type}) of
        ram_copies ->
            ?ets_info(Tab, keypos);
        disc_copies ->
            ?ets_info(Tab, keypos);
        disc_only_copies ->
            dets:info(Tab, keypos);
        {ext, Mod, Alias} ->
            Mod:info(Alias, keypos)
    end.

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
obsolete(Tab, {Ts1, {_Op1, V1}}, {Ts2, {_Op2, V2}}) ->
    equals(Tab, V1, V2) andalso mnesia_causal:compare_vclock(Ts1, Ts2) =:= lt.

-spec equals(mnesia:table(), tuple(), tuple()) -> boolean().
equals(Tab, V1, V2) ->
    case val({Tab, setorbag}) of
        prwset ->
            element(key_pos(Tab), V1) =:= element(key_pos(Tab), V2);
        prwbag ->
            V1 =:= V2;
        Other ->
            error({bad_val, Other})
    end.

-spec get_val_key(mnesia:table(), tuple()) -> term().
get_val_key(Tab, V) ->
    element(key_pos(Tab), V).

add_op(Obj, Op) ->
    erlang:append_element(Obj, Op).

get_op(Obj) ->
    element(tuple_size(Obj), Obj).

get_ts(Obj) ->
    get_ts(tuple_size(Obj) - 1, Obj).

get_ts(Idx, Obj) ->
    element(Idx, Obj).

% set_ts(Obj, Ts) ->
%     setelement(tuple_size(Obj) - 1, Obj, Ts).

set_ts(Obj, Ts, Idx) ->
    setelement(Idx, Obj, Ts).

-spec delete_meta(tuple()) -> tuple().
delete_meta(Obj) ->
    Last = tuple_size(Obj),
    erlang:delete_element(Last - 1, erlang:delete_element(Last, Obj)).

wild_ts_op(Pat) ->
    erlang:append_element(wild_ts(Pat), '_').

wild_ts(Pat) ->
    erlang:append_element(Pat, '_').
