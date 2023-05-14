-module(mnesia_causal_test).

-author('sl955@cam.ac.uk').

-include("mnesia_test_lib.hrl").

-export([init_per_testcase/2, end_per_testcase/2, init_per_group/2, end_per_group/2,
         all/0, groups/0]).
-export([empty_final_buffer_ram/1, causal_stability_basic/1, causal_stability_more/1]).

init_per_testcase(Func, Conf) ->
    mnesia_test_lib:init_per_testcase(Func, Conf).

end_per_testcase(Func, Conf) ->
    mnesia_test_lib:end_per_testcase(Func, Conf).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
all() ->
    [empty_final_buffer_ram, {group, causal_stability}].

groups() ->
    [{causal_stability, [], [causal_stability_basic, causal_stability_more]}].

init_per_group(_GroupName, Config) ->
    Config.

end_per_group(_GroupName, Config) ->
    Config.

empty_final_buffer_ram(suite) ->
    [];
empty_final_buffer_ram(Config) when is_list(Config) ->
    empty_final_buffer(Config, ram_copies).

empty_final_buffer(Config, Storage) ->
    Nodes = [_NodeA, NodeA1, NodeA2] = NodeNames = ?acquire_nodes(3, Config),
    Tab = empty_final_buffer,
    Def = [{Storage, NodeNames}, {type, pawset}, {attributes, [k, v]}],
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),

    Writer = fun(K, V) -> mnesia:write({Tab, K, V}) end,
    ?match(ok,
           mnesia:activity(async_ec,
                           fun() ->
                              Writer(2, a),
                              Writer(1, a)
                           end)),
    spawn_monitor(NodeA1,
                  mnesia,
                  async_ec,
                  [fun() -> [Writer(N, a) || N <- lists:seq(3, 10)] end]),
    spawn_monitor(NodeA1,
                  mnesia,
                  async_ec,
                  [fun() -> [Writer(N, b) || N <- lists:seq(12, 20)] end]),

    timer:sleep(3000),

    ?match([], mnesia_causal:get_buffered()),
    ?match([], rpc:call(NodeA1, mnesia_causal, get_buffered, [])),
    ?match([], rpc:call(NodeA2, mnesia_causal, get_buffered, [])),

    ?verify_mnesia(Nodes, []).

causal_stability_basic(suite) ->
    [];
causal_stability_basic(Config) when is_list(Config) ->
    Nodes = [NodeA, NodeA1, NodeA2] = ?acquire_nodes(3, Config),
    Tab = causal_stability,
    Def = [{ram_copies, Nodes}, {type, pawset}, {attributes, [k, v]}],
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
                                    NodeA2 => 0,
                                    sender => NodeA}
                                  )).

causal_stability_more(suite) ->
    [];
causal_stability_more(Config) when is_list(Config) ->
    Nodes = [NodeA, NodeA1, NodeA2] = ?acquire_nodes(3, Config),
    Tab = causal_stable_receiver,
    Def = [{ram_copies, Nodes}, {type, pawset}, {attributes, [k, v]}],
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),
    ?match(ok, mnesia:activity(sync_ec, fun() -> mnesia:write({Tab, 1, a}) end)),
    spawn(NodeA1, mnesia, sync_ec, [fun() -> mnesia:write({Tab, 2, a}) end]),
    spawn(NodeA2, mnesia, sync_ec, [fun() -> mnesia:write({Tab, 3, a}) end]),
    timer:sleep(500),
    ?match([{Tab, 3, a}], mnesia:sync_ec(fun() -> mnesia:read({Tab, 3}) end)),
    ?match([{Tab, 2, a}], mnesia:sync_ec(fun() -> mnesia:read({Tab, 2}) end)),

    ?match(ok, mnesia:activity(sync_ec, fun() -> mnesia:write({Tab, 4, a}) end)),
    spawn(NodeA1, mnesia, sync_ec, [fun() -> mnesia:write({Tab, 5, a}) end]),
    spawn(NodeA2, mnesia, sync_ec, [fun() -> mnesia:write({Tab, 6, a}) end]),
    timer:sleep(500),
    ?match([{Tab, 4, a}], mnesia:sync_ec(fun() -> mnesia:read({Tab, 4}) end)),
    ?match([{Tab, 6, a}], mnesia:sync_ec(fun() -> mnesia:read({Tab, 6}) end)),

    ?match(true,
           mnesia_causal:tcstable(#{NodeA => 1,
                                    NodeA1 => 0,
                                    NodeA2 => 0,
                                    sender => NodeA})),
    ?match(true,
           mnesia_causal:tcstable(#{NodeA => 1,
                                    NodeA1 => 1,
                                    NodeA2 => 0,
                                    sender => NodeA}
                                  )),

    ?match(true,
           mnesia_causal:tcstable(#{NodeA => 1,
                                    NodeA1 => 0,
                                    NodeA2 => 1,
                                    sender => NodeA}
                                  )).
