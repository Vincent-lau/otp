-module(mnesia_porset_test).

-author('sl955@cam.ac.uk').

-include("mnesia_test_lib.hrl").

-export([init_per_testcase/2, end_per_testcase/2, init_per_group/2, end_per_group/2,
         all/0, groups/0]).
-export([match_delete_ram/1, match_object_ram/1, stable_remove_ts/1]).

init_per_testcase(Func, Conf) ->
    mnesia_test_lib:init_per_testcase(Func, Conf).

end_per_testcase(Func, Conf) ->
    mnesia_test_lib:end_per_testcase(Func, Conf).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
all() ->
    [match_delete_ram, match_object_ram, stable_remove_ts].

groups() ->
    [{write_tests, [], [match_delete_ram]}].

init_per_group(_GroupName, Config) ->
    Config.

end_per_group(_GroupName, Config) ->
    Config.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

match_delete_ram(suite) ->
    [];
match_delete_ram(Config) when is_list(Config) ->
    match_delete(Config, ram_copies).

match_delete(Config, Storage) ->
    Nodes = [_NodeA, NodeA1, NodeA2] = NodeNames = ?acquire_nodes(3, Config),
    Tab = match_delete,
    Def = [{Storage, NodeNames}, {type, porbag}, {attributes, [k, v]}],
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),
    Reader = fun() -> mnesia:read(Tab, a) end,
    Writer = fun(K, V) -> mnesia:write({Tab, K, V}) end,
    ObjectDeleter = fun() -> mnesia:delete_object({Tab, a, 1}) end,
    ?match(ok,
           mnesia:activity(sync_ec,
                           fun() ->
                              Writer(a, 1),
                              Writer(a, 2)
                           end)),
    ?match([{Tab, a, 1}, {Tab, a, 2}], mnesia:activity(sync_ec, Reader)),
    ?match([{Tab, a, 1}, {Tab, a, 2}],
           rpc:call(NodeA1, mnesia, activity, [sync_ec, Reader])),    % %% Delete the record
    ?match([{Tab, a, 1}, {Tab, a, 2}], rpc:call(NodeA2, mnesia, activity, [sync_ec, Reader])),
    ?match(ok, mnesia:sync_ec(ObjectDeleter)),

    ?match([{Tab, a, 2}], mnesia:async_ec(Reader)),
    ?verify_mnesia(Nodes, []).

match_object_ram(suite) ->
    [];
match_object_ram(Config) when is_list(Config) ->
    match_object(Config, ram_copies).

match_object(Config, Storage) ->
    Nodes = [_NodeA, NodeA1, NodeA2] = NodeNames = ?acquire_nodes(3, Config),
    Tab = match_object,
    Def = [{Storage, NodeNames}, {type, porbag}, {attributes, [k, v]}],
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),
    Reader = fun() -> mnesia:read(Tab, a) end,
    Writer = fun(K, V) -> mnesia:write({Tab, K, V}) end,
    ObjectMatcher = fun(Pat) -> mnesia:match_object(Pat) end,

    ?match(ok,
           mnesia:activity(sync_ec,
                           fun() ->
                              Writer(a, 1),
                              Writer(a, 2),
                              Writer(b, 2)
                           end)),

    ?match([{Tab, a, 1}, {Tab, a, 2}], mnesia:activity(sync_ec, Reader)),
    ?match([{Tab, b, 2}], mnesia:activity(sync_ec, fun() -> mnesia:read(Tab, b) end)),

    ?match([{Tab, a, 1}, {Tab, a, 2}],
           lists:sort(
               mnesia:async_ec(fun() -> ObjectMatcher({Tab, a, '_'}) end))),
    ?match([{Tab, a, 2}, {Tab, b, 2}],
           lists:sort(
               rpc:call(NodeA1, mnesia, async_ec, [fun() -> ObjectMatcher({Tab, '_', 2}) end]))),

    ?match(ok, mnesia:sync_ec(fun() -> mnesia:delete_object({Tab, a, 1}) end)),

    ?match([{Tab, a, 2}],
           rpc:call(NodeA2, mnesia, async_ec, [fun() -> ObjectMatcher({Tab, a, '_'}) end])),

    ?verify_mnesia(Nodes, []).

stable_remove_ts(suite) ->
    [];
stable_remove_ts(Config) when is_list(Config) ->
    Nodes = [NodeA, NodeA1, NodeA2]= ?acquire_nodes(3, Config),
    Tab = stable,
    Def = [{ram_copies, Nodes}, {type, porset}, {attributes, [k, v]}],
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),
    ?match(ok, mnesia:activity(sync_ec, fun() -> mnesia:write({Tab, 1, a}) end)),
    spawn(NodeA1, mnesia, sync_ec, [fun() -> mnesia:write({Tab, 2, a}) end]),
    spawn(NodeA2, mnesia, sync_ec, [fun() -> mnesia:write({Tab, 3, a}) end]),
    timer:sleep(500),
    ?match([{Tab, 3, a}], mnesia:sync_ec(fun() -> mnesia:read({Tab, 3}) end)),
    ?match([{Tab, 2, a}], mnesia:sync_ec(fun() -> mnesia:read({Tab, 2}) end)),
    ?match(true,
           mnesia_causal:tcstable(#{NodeA => 1,
                                    NodeA1 => 0,
                                    NodeA2 => 0})),
    timer:sleep(1000),
    ?match([{Tab, 1, a, #{}, write}],
           lists:filter(fun(Tup) -> element(2, Tup) =:= 1 end, ets:tab2list(Tab))).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
