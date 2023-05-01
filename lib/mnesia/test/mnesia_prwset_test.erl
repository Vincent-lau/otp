-module(mnesia_prwset_test).

-author('sl955@cam.ac.uk').

-include("mnesia_test_lib.hrl").

-export([init_per_testcase/2, end_per_testcase/2, init_per_group/2, end_per_group/2,
         all/0, groups/0]).
-export([match_delete_ram/1, match_object_ram/1, remove_wins_ram/1]).

init_per_testcase(Func, Conf) ->
    mnesia_test_lib:init_per_testcase(Func, Conf).

end_per_testcase(Func, Conf) ->
    mnesia_test_lib:end_per_testcase(Func, Conf).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
all() ->
    [remove_wins_ram, match_delete_ram, match_object_ram].

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
    Def = [{Storage, NodeNames}, {type, prwbag}, {attributes, [k, v]}],
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
    Def = [{Storage, NodeNames}, {type, prwbag}, {attributes, [k, v]}],
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

remove_wins_ram(suite) ->
    [];
remove_wins_ram(Config) when is_list(Config) ->
    remove_wins([{is_port, true} | Config], ram_copies).

remove_wins(Config, Storage) ->
    [NodeA, NodeA1, NodeA2] = NodeNames = ?acquire_nodes(3, Config),
    timer:sleep(500),
    Tab = remove_wins,
    Def = [{Storage, NodeNames}, {type, prwset}, {attributes, [k, v]}],
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),

    Reader = fun() -> mnesia:read(Tab, a) end,
    Writer = fun() -> mnesia:write({Tab, a, 1}) end,
    Deleter = fun() -> mnesia:delete({Tab, a}) end,
    BlockAndWrite =
        fun() ->
           % block connnection from NodeA1 to NodeA
           % if called at A1
           inet_tcp_proxy_dist:block(NodeA),
           timer:sleep(500),
           mnesia:async_ec(Writer)
        end,
    spawn(NodeA1, BlockAndWrite),
    timer:sleep(1000),
    ?match([], mnesia:async_ec(Reader)),
    ?match(ok, mnesia:async_ec(Writer)),
    ?match([{Tab, a, 1}], mnesia:async_ec(Reader)),
    ?match(ok, mnesia:async_ec(Deleter)),

    % allow connection
    spawn(NodeA1, fun() -> inet_tcp_proxy_dist:allow(NodeA) end),
    timer:sleep(1000),

    % remove wins semantics
    ?match([], mnesia:async_ec(Reader)),
    ?match([], rpc:call(NodeA1, mnesia, async_ec, [Reader])),
    ?match([], rpc:call(NodeA2, mnesia, async_ec, [Reader])),

    ?verify_mnesia(NodeNames, []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
