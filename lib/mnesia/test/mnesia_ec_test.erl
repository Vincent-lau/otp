-module(mnesia_ec_test).

-author('sl955@cam.ac.uk').

-include("mnesia_test_lib.hrl").

-export([init_per_testcase/2, end_per_testcase/2, init_per_group/2, end_per_group/2,
         all/0, groups/0]).
-export([ec_write_ram/1, ec_write_disc/1, ec_write_disc_only/1, ec_write_xets/1,
         ec_read_ram/1, ec_read_disc/1, ec_read_disc_only/1, ec_read_xets/1,
         ec_update_counter_ram/1, ec_update_counter_disc/1, ec_update_counter_disc_only/1,
         ec_update_counter_xets/1, ec_delete_ram/1, ec_delete_disc/1, ec_delete_disc_only/1,
         ec_delete_xets/1, ec_delete_object_ram/1, ec_delete_object_disc/1,
         ec_delete_object_disc_only/1, ec_delete_object_xets/1, ec_match_object_ram/1,
         ec_match_object_disc/1, ec_match_object_disc_only/1, ec_match_object_xets/1,
         ec_index_match_object_ram/1, ec_index_match_object_disc/1,
         ec_index_match_object_disc_only/1, ec_index_match_object_xets/1, ec_index_read_ram/1,
         ec_index_read_disc/1, ec_index_read_disc_only/1, ec_index_read_xets/1,
         ec_index_update_set_ram/1, ec_index_update_set_disc/1, ec_index_update_set_disc_only/1,
         ec_index_update_set_xets/1, ec_index_update_bag_ram/1, ec_index_update_bag_disc/1,
         ec_index_update_bag_disc_only/1, ec_index_update_bag_xets/1, ec_iter_ram/1,
         ec_iter_disc/1, ec_iter_disc_only/1, ec_iter_xets/1, del_table_copy_1/1,
         del_table_copy_2/1, del_table_copy_3/1, add_table_copy_1/1, add_table_copy_2/1,
         add_table_copy_3/1, add_table_copy_4/1, move_table_copy_1/1, move_table_copy_2/1,
         move_table_copy_3/1, move_table_copy_4/1, ec_error_stacktrace/1]).
-export([ec_rw_ram/1, ec_rw_compare_dirty_ram/1, ec_rwd_ram/1]).
-export([update_trans/3]).

init_per_testcase(Func, Conf) ->
    mnesia_test_lib:init_per_testcase(Func, Conf).

end_per_testcase(Func, Conf) ->
    mnesia_test_lib:end_per_testcase(Func, Conf).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
all() ->
    %     {group, ec_write},
    % {group, ec_read},
    % {group, ec_delete},
    [{group, ec_cc_crud}].

%  {group, ec_update_counter},

    %  {group, ec_delete_object},
    %  {group, ec_match_object}, {group, ec_index},
    %  {group, ec_iter}, {group, admin_tests}, ec_error_stacktrace].

groups() ->
    [{ec_write, [], [ec_write_ram, ec_write_disc]},
     {ec_read, [], [ec_read_ram, ec_read_disc]},
     {ec_update_counter,
      [],
      [ec_update_counter_ram,
       ec_update_counter_disc,
       ec_update_counter_disc_only,
       ec_update_counter_xets]},
     {ec_delete, [], [ec_delete_ram, ec_delete_disc]},
     {ec_cc_crud, [], [ec_rw_ram]},
     {ec_delete_object,
      [],
      [ec_delete_object_ram,
       ec_delete_object_disc,
       ec_delete_object_disc_only,
       ec_delete_object_xets]},
     {ec_match_object,
      [],
      [ec_match_object_ram,
       ec_match_object_disc,
       ec_match_object_disc_only,
       ec_match_object_xets]},
     {ec_index,
      [],
      [{group, ec_index_match_object}, {group, ec_index_read}, {group, ec_index_update}]},
     {ec_index_match_object,
      [],
      [ec_index_match_object_ram,
       ec_index_match_object_disc,
       ec_index_match_object_disc_only,
       ec_index_match_object_xets]},
     {ec_index_read,
      [],
      [ec_index_read_ram, ec_index_read_disc, ec_index_read_disc_only, ec_index_read_xets]},
     {ec_index_update,
      [],
      [ec_index_update_set_ram,
       ec_index_update_set_disc,
       ec_index_update_set_disc_only,
       ec_index_update_set_xets,
       ec_index_update_bag_ram,
       ec_index_update_bag_disc,
       ec_index_update_bag_disc_only,
       ec_index_update_bag_xets]},
     {ec_iter, [], [ec_iter_ram, ec_iter_disc, ec_iter_disc_only, ec_iter_xets]},
     {admin_tests,
      [],
      [del_table_copy_1,
       del_table_copy_2,
       del_table_copy_3,
       add_table_copy_1,
       add_table_copy_2,
       add_table_copy_3,
       add_table_copy_4,
       move_table_copy_1,
       move_table_copy_2,
       move_table_copy_3,
       move_table_copy_4]}].

init_per_group(ec_cc_crud, Config) ->
    [{is_port, true} | Config];
init_per_group(_GroupName, Config) ->
    Config.

end_per_group(_GroupName, Config) ->
    Config.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Errors in ec activity should have stacktrace
ec_error_stacktrace(_Config) ->
    %% Custom errors should have stacktrace
    try
        mnesia:async_ec(fun() -> error(custom_error) end)
    catch
        exit:{custom_error, _} ->
            ok
    end,

    %% Undef error should have unknown module and function in the stacktrace
    try
        mnesia:async_ec(fun() -> unknown_module:unknown_fun(arg) end)
    catch
        exit:{undef, [{unknown_module, unknown_fun, [arg], []} | _]} ->
            ok
    end,

    %% Exists don't have stacktrace
    try
        mnesia:async_ec(fun() -> exit(custom_error) end)
    catch
        exit:custom_error ->
            ok
    end,

    %% Aborts don't have a stacktrace (unfortunately)
    try
        mnesia:async_ec(fun() -> mnesia:abort(custom_abort) end)
    catch
        exit:{aborted, custom_abort} ->
            ok
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Concurrent read and write
%% Requires a custom distrbution protocol https://github.com/rabbitmq/inet_tcp_proxy
%% for simulating network partitions

ec_rw_ram(suite) ->
    [];
ec_rw_ram(Config) when is_list(Config) ->
    ec_rw(Config, ram_copies).

ec_rw(Config, Storage) ->
    [NodeA, NodeA1, NodeA2] = NodeNames = ?acquire_nodes(3, Config),
    Tab = ec_rw,
    Def = [{Storage, NodeNames}, {type, porset}, {attributes, [k, v]}],
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),

    Reader = fun() -> mnesia:read(Tab, a) end,
    Writer = fun() -> mnesia:write({Tab, a, 1}) end,
    Deleter = fun() -> mnesia:delete({Tab, a}) end,
    BlockAndWrite =
        fun() ->
           % block connnection from NodeA1 to NodeA
           % if called at A1
           inet_tcp_proxy_dist:block(NodeA),
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
    ?match([{Tab, a, 1}], mnesia:async_ec(Reader)),
    ?match([{Tab, a, 1}], rpc:call(NodeA1, mnesia, async_ec, [Reader])),
    ?match([{Tab, a, 1}], rpc:call(NodeA2, mnesia, async_ec, [Reader])).

ec_rwd_ram(suite) ->
    [];
ec_rwd_ram(Config) ->
    ec_rwd(Config, ram_copies).

ec_rwd(Config, Storage) ->
    Nodes = [_NodeA, NodeA1, NodeA2] = ?acquire_nodes(3, Config),
    Tab = ec_rwd,
    Def = [{Storage, Nodes}, {type, porset}, {attributes, [k, v]}],
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),
    Writer = fun(K, V) -> mnesia:write({Tab, K, V}) end,
    Deleter = fun(K) -> mnesia:delete({Tab, K}) end,

    spawn(fun() ->
             lists:foreach(fun(N) -> mnesia:async_ec(fun() -> Writer(N, 4) end) end,
                           lists:seq(1, 20))
          end),
    spawn(fun() ->
             mnesia_rpc:call(NodeA1,
                             lists,
                             foreach,
                             [fun(N) -> mnesia:async_ec(fun() -> Writer(N, 4) end) end,
                              lists:seq(21, 30)])
          end),
    spawn(fun() ->
             mnesia_rpc:call(NodeA2,
                             lists,
                             foreach,
                             [fun(N) -> mnesia:async_ec(fun() -> Writer(N, 4) end) end,
                              lists:seq(31, 40)])
          end),

    timer:sleep(1000),
    spawn(fun() ->
             mnesia_rpc:call(NodeA1,
                             lists,
                             foreach,
                             [fun(N) -> mnesia:async_ec(fun() -> Deleter(N) end) end,
                              lists:seq(20, 34)])
          end),

    timer:sleep(1000),
    Res = lists:seq(1, 40) -- lists:seq(20, 34),
    ?match(Res,
           lists:sort(
               mnesia:async_ec(fun() -> mnesia:all_keys(Tab) end))).

ec_rw_compare_dirty_ram(suite) ->
    [];
ec_rw_compare_dirty_ram(Config) ->
    ec_rw_compare_dirty(Config, ram_copies).

ec_rw_compare_dirty(Config, Storage) ->
    Nodes = [_NodeA, NodeA1, NodeA2] = ?acquire_nodes(3, Config),
    Tab1 = ec_rw,
    Tab2 = dirty_rw,
    Def1 = [{Storage, Nodes}, {type, porset}, {attributes, [k, v]}],
    Def2 = [{Storage, Nodes}, {type, porset}, {attributes, [k, v]}],
    ?match({atomic, ok}, mnesia:create_table(Tab1, Def1)),
    ?match({atomic, ok}, mnesia:create_table(Tab2, Def2)),

    % Reader = fun(K) -> mnesia:read(Tab1, K) end,
    Writer = fun(K, V) -> mnesia:write({Tab1, K, V}) end,
    % Deleter = fun(K) -> mnesia:delete({Tab1, K}) end,
    spawn(fun() -> [mnesia:dirty_write({Tab2, N, 1}) || N <- lists:seq(1, 20)] end),
    spawn(fun() ->
             mnesia_rpc:call(NodeA1,
                             lists,
                             foreach,
                             [fun(N) -> mnesia:dirty_write({Tab2, N, 2}) end, lists:seq(21, 30)])
          end),
    spawn(fun() ->
             mnesia_rpc:call(NodeA2,
                             lists,
                             foreach,
                             [fun(N) -> mnesia:dirty_write({Tab2, N, 3}) end, lists:seq(31, 40)])
          end),

    spawn(fun() ->
             lists:foreach(fun(N) -> mnesia:async_ec(fun() -> Writer(N, 4) end) end,
                           lists:seq(1, 20))
          end),
    spawn(fun() ->
             mnesia_rpc:call(NodeA1,
                             lists,
                             foreach,
                             [fun(N) -> mnesia:async_ec(fun() -> Writer(N, 5) end) end,
                              lists:seq(21, 30)])
          end),
    spawn(fun() ->
             mnesia_rpc:call(NodeA2,
                             lists,
                             foreach,
                             [fun(N) -> mnesia:async_ec(fun() -> Writer(N, 6) end) end,
                              lists:seq(31, 40)])
          end),

    timer:sleep(1000),

    AllKeys =
        lists:sort(
            mnesia:dirty_all_keys(Tab2)),
    io:foramt("AllKeys on dirty table: ~p~n allkeys on ec table: ~p~n",
              [AllKeys,
               lists:sort(
                   mnesia:async_ec(fun() -> mnesia:all_keys(Tab1) end))]),
    ?match(AllKeys,
           lists:sort(
               mnesia:async_ec(fun() -> mnesia:all_keys(Tab1) end))).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Write records ec

ec_write_ram(suite) ->
    [];
ec_write_ram(Config) when is_list(Config) ->
    ec_write(Config, ram_copies).

ec_write_disc(suite) ->
    [];
ec_write_disc(Config) when is_list(Config) ->
    ec_write(Config, disc_copies).

ec_write_disc_only(suite) ->
    [];
ec_write_disc_only(Config) when is_list(Config) ->
    ec_write(Config, disc_only_copies).

ec_write_xets(Config) when is_list(Config) ->
    ec_write(Config, ext_ets).

ec_write(Config, Storage) ->
    [Node1] = Nodes = ?acquire_nodes(1, Config),
    Tab = ec_write,
    Def = [{type, porset}, {attributes, [k, v]}, {Storage, [Node1]}],
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),

    ?match({'EXIT', _}, mnesia:async_ec(fun mnesia:write/1, [])),
    ?match({'EXIT', _}, mnesia:async_ec(fun mnesia:write/1, [{Tab, 2}])),
    ?match({'EXIT', _}, mnesia:async_ec(fun mnesia:write/1, [{foo, 2}])),
    ?match(ok, mnesia:async_ec(fun mnesia:write/1, [{Tab, 1, 2}])),
    ?verify_mnesia(Nodes, []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Read records ec

ec_read_ram(suite) ->
    [];
ec_read_ram(Config) when is_list(Config) ->
    ec_read(Config, ram_copies).

ec_read_disc(suite) ->
    [];
ec_read_disc(Config) when is_list(Config) ->
    ec_read(Config, disc_copies).

ec_read_disc_only(suite) ->
    [];
ec_read_disc_only(Config) when is_list(Config) ->
    ec_read(Config, disc_only_copies).

ec_read_xets(Config) when is_list(Config) ->
    ec_read(Config, ext_ets).

ec_read(Config, Storage) ->
    [Node1] = Nodes = ?acquire_nodes(1, Config),
    Tab = ec_read,
    Def = [{type, porset}, {attributes, [k, v]}, {Storage, [Node1]}],
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),

    ?match({'EXIT', _}, mnesia:async_ec(fun mnesia:read/1, [[]])),
    ?match({'EXIT', _}, mnesia:async_ec(fun mnesia:read/1, [{Tab}])),
    ?match({'EXIT', _}, mnesia:async_ec(fun mnesia:read/1, [{Tab, 1, 2}])),
    ?match([], mnesia:async_ec(fun mnesia:read/1, [{Tab, 1}])),
    ?match(ok, mnesia:async_ec(fun mnesia:write/1, [{Tab, 1, 2}])),
    ?match([{Tab, 1, 2}], mnesia:async_ec(fun mnesia:read/1, [{Tab, 1}])),
    ?match(ok, mnesia:async_ec(fun mnesia:write/1, [{Tab, 1, 3}])),
    ?match([{Tab, 1, 3}], mnesia:async_ec(fun mnesia:read/1, [{Tab, 1}])),

    ?match(false, mnesia:async_ec(fun() -> mnesia:is_transaction() end)),
    ?match(false, mnesia:ets(fun() -> mnesia:is_transaction() end)),
    ?match(false, mnesia:activity(async_ec, fun() -> mnesia:is_transaction() end)),
    ?match(false, mnesia:activity(ets, fun() -> mnesia:is_transaction() end)),

    ?verify_mnesia(Nodes, []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Update counter record ec

ec_update_counter_ram(suite) ->
    [];
ec_update_counter_ram(Config) when is_list(Config) ->
    ec_update_counter(Config, ram_copies).

ec_update_counter_disc(suite) ->
    [];
ec_update_counter_disc(Config) when is_list(Config) ->
    ec_update_counter(Config, disc_copies).

ec_update_counter_disc_only(suite) ->
    [];
ec_update_counter_disc_only(Config) when is_list(Config) ->
    ec_update_counter(Config, disc_only_copies).

ec_update_counter_xets(Config) when is_list(Config) ->
    ec_update_counter(Config, ext_ets).

ec_update_counter(Config, Storage) ->
    [Node1] = Nodes = ?acquire_nodes(1, Config),
    Tab = ec_update_counter,
    Def = [{attributes, [k, v]}, {Storage, [Node1]}],
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),
    ?match(ok, mnesia:ec_write({Tab, 1, 2})),

    ?match({'EXIT', _}, mnesia:ec_update_counter({Tab, 1}, [])),
    ?match({'EXIT', _}, mnesia:ec_update_counter({Tab}, 3)),
    ?match({'EXIT', _}, mnesia:ec_update_counter({foo, 1}, 3)),
    ?match(5, mnesia:ec_update_counter({Tab, 1}, 3)),
    ?match([{Tab, 1, 5}], mnesia:ec_read({Tab, 1})),

    ?match({atomic, 8},
           mnesia:transaction(fun() -> mnesia:ec_update_counter({Tab, 1}, 3) end)),

    ?match(1, mnesia:ec_update_counter({Tab, foo}, 1)),
    ?match([{Tab, foo, 1}], mnesia:ec_read({Tab, foo})),

    ?match({ok, _}, mnesia:subscribe({table, Tab, detailed})),

    ?match(2, mnesia:ec_update_counter({Tab, foo}, 1)),
    ?match([{Tab, foo, 2}], mnesia:ec_read({Tab, foo})),

    ?verify_mnesia(Nodes, []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Delete record ec

ec_delete_ram(suite) ->
    [];
ec_delete_ram(Config) when is_list(Config) ->
    ec_delete(Config, ram_copies).

ec_delete_disc(suite) ->
    [];
ec_delete_disc(Config) when is_list(Config) ->
    ec_delete(Config, disc_copies).

ec_delete_disc_only(suite) ->
    [];
ec_delete_disc_only(Config) when is_list(Config) ->
    ec_delete(Config, disc_only_copies).

ec_delete_xets(Config) when is_list(Config) ->
    ec_delete(Config, ext_ets).

ec_delete(Config, Storage) ->
    [Node1] = Nodes = ?acquire_nodes(1, Config),
    Tab = ec_delete,
    Def = [{type, porset}, {attributes, [k, v]}, {Storage, [Node1]}],
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),

    ?match({'EXIT', _}, mnesia:async_ec(fun mnesia:delete/1, [[]])),
    ?match({'EXIT', _}, mnesia:async_ec(fun mnesia:delete/1, [{Tab}])),
    ?match({'EXIT', _}, mnesia:async_ec(fun mnesia:delete/1, [{Tab, 1, 2}])),
    ?match(ok, mnesia:async_ec(fun mnesia:delete/1, [{Tab, 1}])),
    ?match(ok, mnesia:async_ec(fun mnesia:write/1, [{Tab, 1, 2}])),
    ?match(ok, mnesia:async_ec(fun mnesia:delete/1, [{Tab, 1}])),
    ?match(ok, mnesia:async_ec(fun mnesia:write/1, [{Tab, 1, 2}])),
    ?match(ok, mnesia:async_ec(fun mnesia:write/1, [{Tab, 1, 2}])),
    ?match(ok, mnesia:async_ec(fun mnesia:delete/1, [{Tab, 1}])),

    ?match(ok, mnesia:async_ec(fun mnesia:write/1, [{Tab, 1, 2}])),
    ?verify_mnesia(Nodes, []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Delete matching record ec

ec_delete_object_ram(suite) ->
    [];
ec_delete_object_ram(Config) when is_list(Config) ->
    ec_delete_object(Config, ram_copies).

ec_delete_object_disc(suite) ->
    [];
ec_delete_object_disc(Config) when is_list(Config) ->
    ec_delete_object(Config, disc_copies).

ec_delete_object_disc_only(suite) ->
    [];
ec_delete_object_disc_only(Config) when is_list(Config) ->
    ec_delete_object(Config, disc_only_copies).

ec_delete_object_xets(Config) when is_list(Config) ->
    ec_delete_object(Config, ext_ets).

ec_delete_object(Config, Storage) ->
    [Node1] = Nodes = ?acquire_nodes(1, Config),
    Tab = ec_delete_object,
    Def = [{type, bag}, {attributes, [k, v]}, {Storage, [Node1]}],
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),

    OneRec = {Tab, 1, 2},
    ?match({'EXIT', _}, mnesia:ec_delete_object([])),
    ?match({'EXIT', _}, mnesia:ec_delete_object({Tab})),
    ?match({'EXIT', _}, mnesia:ec_delete_object({Tab, 1})),
    ?match(ok, mnesia:ec_delete_object(OneRec)),
    ?match(ok, mnesia:ec_write(OneRec)),
    ?match(ok, mnesia:ec_delete_object(OneRec)),
    ?match(ok, mnesia:ec_write(OneRec)),
    ?match(ok, mnesia:ec_write(OneRec)),
    ?match(ok, mnesia:ec_delete_object(OneRec)),

    ?match(ok, mnesia:ec_write(OneRec)),
    ?match({atomic, ok}, mnesia:transaction(fun() -> mnesia:ec_delete_object(OneRec) end)),

    ?match({'EXIT', {aborted, {bad_type, Tab, _}}},
           mnesia:ec_delete_object(Tab, {Tab, {['_']}, 21})),
    ?match({'EXIT', {aborted, {bad_type, Tab, _}}},
           mnesia:ec_delete_object(Tab, {Tab, {['$5']}, 21})),

    ?verify_mnesia(Nodes, []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Read matching records ec

ec_match_object_ram(suite) ->
    [];
ec_match_object_ram(Config) when is_list(Config) ->
    ec_match_object(Config, ram_copies).

ec_match_object_disc(suite) ->
    [];
ec_match_object_disc(Config) when is_list(Config) ->
    ec_match_object(Config, disc_copies).

ec_match_object_disc_only(suite) ->
    [];
ec_match_object_disc_only(Config) when is_list(Config) ->
    ec_match_object(Config, disc_only_copies).

ec_match_object_xets(Config) when is_list(Config) ->
    ec_match_object(Config, ext_ets).

ec_match_object(Config, Storage) ->
    [Node1] = Nodes = ?acquire_nodes(1, Config),
    Tab = ec_match,
    Def = [{attributes, [k, v]}, {Storage, [Node1]}],
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),

    OneRec = {Tab, 1, 2},
    OnePat = {Tab, '$1', 2},
    ?match([], mnesia:ec_match_object(OnePat)),
    ?match(ok, mnesia:ec_write(OneRec)),
    ?match([OneRec], mnesia:ec_match_object(OnePat)),
    ?match({atomic, [OneRec]},
           mnesia:transaction(fun() -> mnesia:ec_match_object(OnePat) end)),

    ?match({'EXIT', _}, mnesia:ec_match_object({foo, '$1', 2})),
    ?match({'EXIT', _}, mnesia:ec_match_object({[], '$1', 2})),
    ?verify_mnesia(Nodes, []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% ec read matching records by using an index

ec_index_match_object_ram(suite) ->
    [];
ec_index_match_object_ram(Config) when is_list(Config) ->
    ec_index_match_object(Config, ram_copies).

ec_index_match_object_disc(suite) ->
    [];
ec_index_match_object_disc(Config) when is_list(Config) ->
    ec_index_match_object(Config, disc_copies).

ec_index_match_object_disc_only(suite) ->
    [];
ec_index_match_object_disc_only(Config) when is_list(Config) ->
    ec_index_match_object(Config, disc_only_copies).

ec_index_match_object_xets(Config) when is_list(Config) ->
    ec_index_match_object(Config, ext_ets).

ec_index_match_object(Config, Storage) ->
    [Node1] = Nodes = ?acquire_nodes(1, Config),
    Tab = ec_index_match_object,
    ValPos = 3,
    BadValPos = ValPos + 1,
    Def = [{attributes, [k, v]}, {Storage, [Node1]}, {index, [ValPos]}],
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),

    ?match([], mnesia:ec_index_match_object({Tab, '$1', 2}, ValPos)),
    OneRec = {Tab, 1, 2},
    ?match(ok, mnesia:ec_write(OneRec)),

    ?match([OneRec], mnesia:ec_index_match_object({Tab, '$1', 2}, ValPos)),
    ?match({'EXIT', _}, mnesia:ec_index_match_object({Tab, '$1', 2}, BadValPos)),
    ?match({'EXIT', _}, mnesia:ec_index_match_object({foo, '$1', 2}, ValPos)),
    ?match({'EXIT', _}, mnesia:ec_index_match_object({[], '$1', 2}, ValPos)),
    ?match({atomic, [OneRec]},
           mnesia:transaction(fun() -> mnesia:ec_index_match_object({Tab, '$1', 2}, ValPos) end)),

    ?verify_mnesia(Nodes, []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Read records by using an index

ec_index_read_ram(suite) ->
    [];
ec_index_read_ram(Config) when is_list(Config) ->
    ec_index_read(Config, ram_copies).

ec_index_read_disc(suite) ->
    [];
ec_index_read_disc(Config) when is_list(Config) ->
    ec_index_read(Config, disc_copies).

ec_index_read_disc_only(suite) ->
    [];
ec_index_read_disc_only(Config) when is_list(Config) ->
    ec_index_read(Config, disc_only_copies).

ec_index_read_xets(Config) when is_list(Config) ->
    ec_index_read(Config, ext_ets).

ec_index_read(Config, Storage) ->
    [Node1] = Nodes = ?acquire_nodes(1, Config),
    Tab = ec_index_read,
    ValPos = 3,
    BadValPos = ValPos + 1,
    Def = [{type, set}, {attributes, [k, v]}, {Storage, [Node1]}, {index, [ValPos]}],
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),

    OneRec = {Tab, 1, 2},
    ?match([], mnesia:ec_index_read(Tab, 2, ValPos)),
    ?match(ok, mnesia:ec_write(OneRec)),
    ?match([OneRec], mnesia:ec_index_read(Tab, 2, ValPos)),
    ?match({atomic, [OneRec]},
           mnesia:transaction(fun() -> mnesia:ec_index_read(Tab, 2, ValPos) end)),
    ?match(42, mnesia:ec_update_counter({Tab, 1}, 40)),
    ?match([{Tab, 1, 42}], mnesia:ec_read({Tab, 1})),
    ?match([], mnesia:ec_index_read(Tab, 2, ValPos)),
    ?match([{Tab, 1, 42}], mnesia:ec_index_read(Tab, 42, ValPos)),

    ?match({'EXIT', _}, mnesia:ec_index_read(Tab, 2, BadValPos)),
    ?match({'EXIT', _}, mnesia:ec_index_read(foo, 2, ValPos)),
    ?match({'EXIT', _}, mnesia:ec_index_read([], 2, ValPos)),

    mnesia:ec_write({Tab, 5, 1}),
    ?match(ok, index_read_loop(Tab, 0)),

    ?verify_mnesia(Nodes, []).

index_read_loop(Tab, N) when N =< 1000 ->
    spawn_link(fun() -> mnesia:transaction(fun() -> mnesia:write({Tab, 5, 1}) end) end),
    case mnesia:ec_match_object({Tab, '_', 1}) of
        [{Tab, 5, 1}] ->
            index_read_loop(Tab, N + 1);
        Other ->
            {N, Other}
    end;
index_read_loop(_, _) ->
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
ec_index_update_set_ram(suite) ->
    [];
ec_index_update_set_ram(Config) when is_list(Config) ->
    ec_index_update_set(Config, ram_copies).

ec_index_update_set_disc(suite) ->
    [];
ec_index_update_set_disc(Config) when is_list(Config) ->
    ec_index_update_set(Config, disc_copies).

ec_index_update_set_disc_only(suite) ->
    [];
ec_index_update_set_disc_only(Config) when is_list(Config) ->
    ec_index_update_set(Config, disc_only_copies).

ec_index_update_set_xets(Config) when is_list(Config) ->
    ec_index_update_set(Config, ext_ets).

ec_index_update_set(Config, Storage) ->
    [Node1] = Nodes = ?acquire_nodes(1, Config),
    Tab = index_test,
    ValPos = v1,
    ValPos2 = v3,
    Def = [{attributes, [k, v1, v2, v3]}, {Storage, [Node1]}, {index, [ValPos]}],
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),

    Pat1 = {Tab, '$1', 2, '$2', '$3'},
    Pat2 = {Tab, '$1', '$2', '$3', '$4'},
    Pat3 = {Tab, '_', '_', '_', {4, 14}},

    Rec1 = {Tab, 1, 2, 3, {4, 14}},
    Rec2 = {Tab, 2, 2, 13, 14},
    Rec3 = {Tab, 1, 12, 13, 14},
    Rec4 = {Tab, 4, 2, 13, 14},

    ?match([], mnesia:ec_index_read(Tab, 2, ValPos)),
    ?match(ok, mnesia:ec_write(Rec1)),
    ?match([Rec1], mnesia:ec_index_read(Tab, 2, ValPos)),

    ?match(ok, mnesia:ec_write(Rec2)),
    R1 = mnesia:ec_index_read(Tab, 2, ValPos),
    ?match([Rec1, Rec2], lists:sort(R1)),

    ?match(ok, mnesia:ec_write(Rec3)),
    R2 = mnesia:ec_index_read(Tab, 2, ValPos),
    ?match([Rec2], lists:sort(R2)),
    ?match([Rec2], mnesia:ec_index_match_object(Pat1, ValPos)),

    {atomic, R3} = mnesia:transaction(fun() -> mnesia:match_object(Pat2) end),
    ?match([Rec3, Rec2], lists:sort(R3)),

    ?match(ok, mnesia:ec_write(Rec4)),
    R4 = mnesia:ec_index_read(Tab, 2, ValPos),
    ?match([Rec2, Rec4], lists:sort(R4)),

    ?match(ok, mnesia:ec_delete({Tab, 4})),
    ?match([Rec2], mnesia:ec_index_read(Tab, 2, ValPos)),

    ?match({atomic, ok}, mnesia:del_table_index(Tab, ValPos)),
    ?match({atomic, ok}, mnesia:transaction(fun() -> mnesia:write(Rec4) end)),
    ?match({atomic, ok}, mnesia:add_table_index(Tab, ValPos)),
    ?match({atomic, ok}, mnesia:add_table_index(Tab, ValPos2)),

    R5 = mnesia:ec_match_object(Pat2),
    ?match([Rec3, Rec2, Rec4], lists:sort(R5)),

    R6 = mnesia:ec_index_read(Tab, 2, ValPos),
    ?match([Rec2, Rec4], lists:sort(R6)),
    ?match([], mnesia:ec_index_read(Tab, {4, 14}, ValPos2)),
    R7 = mnesia:ec_index_read(Tab, 14, ValPos2),
    ?match([Rec3, Rec2, Rec4], lists:sort(R7)),

    ?match({atomic, ok}, mnesia:transaction(fun() -> mnesia:write(Rec1) end)),
    R8 = mnesia:ec_index_read(Tab, 2, ValPos),
    ?match([Rec1, Rec2, Rec4], lists:sort(R8)),
    ?match([Rec1], mnesia:ec_index_read(Tab, {4, 14}, ValPos2)),
    ?match([Rec1], mnesia:ec_match_object(Pat3)),
    ?match([Rec1], mnesia:ec_index_match_object(Pat3, ValPos2)),

    R9 = mnesia:ec_index_read(Tab, 14, ValPos2),
    ?match([Rec2, Rec4], lists:sort(R9)),

    ?match({atomic, ok}, mnesia:transaction(fun() -> mnesia:delete_object(Rec2) end)),
    R10 = mnesia:ec_index_read(Tab, 2, ValPos),
    ?match([Rec1, Rec4], lists:sort(R10)),
    ?match([Rec1], mnesia:ec_index_read(Tab, {4, 14}, ValPos2)),
    ?match([Rec4], mnesia:ec_index_read(Tab, 14, ValPos2)),

    ?match(ok, mnesia:ec_delete({Tab, 4})),
    R11 = mnesia:ec_index_read(Tab, 2, ValPos),
    ?match([Rec1], lists:sort(R11)),
    ?match([Rec1], mnesia:ec_index_read(Tab, {4, 14}, ValPos2)),
    ?match([], mnesia:ec_index_read(Tab, 14, ValPos2)),

    ?verify_mnesia(Nodes, []).

ec_index_update_bag_ram(suite) ->
    [];
ec_index_update_bag_ram(Config) when is_list(Config) ->
    ec_index_update_bag(Config, ram_copies).

ec_index_update_bag_disc(suite) ->
    [];
ec_index_update_bag_disc(Config) when is_list(Config) ->
    ec_index_update_bag(Config, disc_copies).

ec_index_update_bag_disc_only(suite) ->
    [];
ec_index_update_bag_disc_only(Config) when is_list(Config) ->
    ec_index_update_bag(Config, disc_only_copies).

ec_index_update_bag_xets(Config) when is_list(Config) ->
    ec_index_update_bag(Config, ext_ets).

ec_index_update_bag(Config, Storage) ->
    [Node1] = Nodes = ?acquire_nodes(1, Config),
    Tab = index_test,
    ValPos = v1,
    ValPos2 = v3,
    Def = [{type, bag}, {attributes, [k, v1, v2, v3]}, {Storage, [Node1]}, {index, [ValPos]}],
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),

    Pat1 = {Tab, '$1', 2, '$2', '$3'},
    Pat2 = {Tab, '$1', '$2', '$3', '$4'},

    Rec1 = {Tab, 1, 2, 3, 4},
    Rec2 = {Tab, 2, 2, 13, 14},
    Rec3 = {Tab, 1, 12, 13, 14},
    Rec4 = {Tab, 4, 2, 13, 4},
    Rec5 = {Tab, 1, 2, 234, 14},

    %% Simple Index
    ?match([], mnesia:ec_index_read(Tab, 2, ValPos)),
    ?match(ok, mnesia:ec_write(Rec1)),
    ?match([Rec1], mnesia:ec_index_read(Tab, 2, ValPos)),

    ?match(ok, mnesia:ec_delete_object(Rec5)),
    ?match([Rec1], mnesia:ec_index_read(Tab, 2, ValPos)),

    ?match({atomic, ok}, mnesia:transaction(fun() -> mnesia:write(Rec2) end)),
    R1 = mnesia:ec_index_read(Tab, 2, ValPos),
    ?match([Rec1, Rec2], lists:sort(R1)),

    ?match(ok, mnesia:ec_write(Rec3)),
    R2 = mnesia:ec_index_read(Tab, 2, ValPos),
    ?match([Rec1, Rec2], lists:sort(R2)),

    R3 = mnesia:ec_index_match_object(Pat1, ValPos),
    ?match([Rec1, Rec2], lists:sort(R3)),

    R4 = mnesia:ec_match_object(Pat2),
    ?match([Rec1, Rec3, Rec2], lists:sort(R4)),

    ?match({atomic, ok}, mnesia:transaction(fun() -> mnesia:write(Rec4) end)),
    R5 = mnesia:ec_index_read(Tab, 2, ValPos),
    ?match([Rec1, Rec2, Rec4], lists:sort(R5)),

    ?match({atomic, ok}, mnesia:transaction(fun() -> mnesia:delete({Tab, 4}) end)),
    R6 = mnesia:ec_index_read(Tab, 2, ValPos),
    ?match([Rec1, Rec2], lists:sort(R6)),

    ?match(ok, mnesia:ec_delete_object(Rec1)),
    ?match([Rec2], mnesia:ec_index_read(Tab, 2, ValPos)),
    R7 = mnesia:ec_match_object(Pat2),
    ?match([Rec3, Rec2], lists:sort(R7)),

    %% Two indexies
    ?match({atomic, ok}, mnesia:del_table_index(Tab, ValPos)),
    ?match({atomic, ok}, mnesia:transaction(fun() -> mnesia:write(Rec1) end)),
    ?match({atomic, ok}, mnesia:transaction(fun() -> mnesia:write(Rec4) end)),
    ?match({atomic, ok}, mnesia:add_table_index(Tab, ValPos)),
    ?match({atomic, ok}, mnesia:add_table_index(Tab, ValPos2)),

    R8 = mnesia:ec_index_read(Tab, 2, ValPos),
    ?match([Rec1, Rec2, Rec4], lists:sort(R8)),

    R9 = mnesia:ec_index_read(Tab, 4, ValPos2),
    ?match([Rec1, Rec4], lists:sort(R9)),
    R10 = mnesia:ec_index_read(Tab, 14, ValPos2),
    ?match([Rec3, Rec2], lists:sort(R10)),

    ?match({atomic, ok}, mnesia:transaction(fun() -> mnesia:write(Rec5) end)),
    R11 = mnesia:ec_index_read(Tab, 2, ValPos),
    ?match([Rec1, Rec5, Rec2, Rec4], lists:sort(R11)),
    R12 = mnesia:ec_index_read(Tab, 4, ValPos2),
    ?match([Rec1, Rec4], lists:sort(R12)),
    R13 = mnesia:ec_index_read(Tab, 14, ValPos2),
    ?match([Rec5, Rec3, Rec2], lists:sort(R13)),

    ?match({atomic, ok}, mnesia:transaction(fun() -> mnesia:delete_object(Rec1) end)),
    R14 = mnesia:ec_index_read(Tab, 2, ValPos),
    ?match([Rec5, Rec2, Rec4], lists:sort(R14)),
    ?match([Rec4], mnesia:ec_index_read(Tab, 4, ValPos2)),
    R15 = mnesia:ec_index_read(Tab, 14, ValPos2),
    ?match([Rec5, Rec3, Rec2], lists:sort(R15)),

    ?match(ok, mnesia:ec_delete_object(Rec5)),
    R16 = mnesia:ec_index_read(Tab, 2, ValPos),
    ?match([Rec2, Rec4], lists:sort(R16)),
    ?match([Rec4], mnesia:ec_index_read(Tab, 4, ValPos2)),
    R17 = mnesia:ec_index_read(Tab, 14, ValPos2),
    ?match([Rec3, Rec2], lists:sort(R17)),

    ?match(ok, mnesia:ec_write(Rec1)),
    ?match(ok, mnesia:ec_delete({Tab, 1})),
    R18 = mnesia:ec_index_read(Tab, 2, ValPos),
    ?match([Rec2, Rec4], lists:sort(R18)),
    ?match([Rec4], mnesia:ec_index_read(Tab, 4, ValPos2)),
    R19 = mnesia:ec_index_read(Tab, 14, ValPos2),
    ?match([Rec2], lists:sort(R19)),

    ?verify_mnesia(Nodes, []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% ec iteration
%% ec_slot,  ec_first,  ec_next

ec_iter_ram(suite) ->
    [];
ec_iter_ram(Config) when is_list(Config) ->
    ec_iter(Config, ram_copies).

ec_iter_disc(suite) ->
    [];
ec_iter_disc(Config) when is_list(Config) ->
    ec_iter(Config, disc_copies).

ec_iter_disc_only(suite) ->
    [];
ec_iter_disc_only(Config) when is_list(Config) ->
    ec_iter(Config, disc_only_copies).

ec_iter_xets(Config) when is_list(Config) ->
    ec_iter(Config, ext_ets).

ec_iter(Config, Storage) ->
    [Node1] = Nodes = ?acquire_nodes(1, Config),
    Tab = ec_iter,
    Def = [{type, bag}, {attributes, [k, v]}, {Storage, [Node1]}],
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),

    ?match([], all_slots(Tab)),
    ?match([], all_nexts(Tab)),

    Keys = lists:seq(1, 5),
    Records = [{Tab, A, B} || A <- Keys, B <- lists:seq(1, 2)],
    lists:foreach(fun(Rec) -> ?match(ok, mnesia:ec_write(Rec)) end, Records),

    SortedRecords = lists:sort(Records),
    ?match(SortedRecords, lists:sort(all_slots(Tab))),
    ?match(Keys, lists:sort(all_nexts(Tab))),

    ?match({'EXIT', _}, mnesia:ec_first(foo)),
    ?match({'EXIT', _}, mnesia:ec_next(foo, foo)),
    ?match({'EXIT', _}, mnesia:ec_slot(foo, 0)),
    ?match({'EXIT', _}, mnesia:ec_slot(foo, [])),
    ?match({atomic, Keys}, mnesia:transaction(fun() -> lists:sort(all_nexts(Tab)) end)),
    ?verify_mnesia(Nodes, []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Returns a list of all keys in table
all_slots(Tab) ->
    all_slots(Tab, [], 0).

all_slots(_Tab, '$end_of_table', _) ->
    [];
all_slots(Tab, PrevRecords, PrevSlot) ->
    Records = mnesia:ec_slot(Tab, PrevSlot),
    PrevRecords ++ all_slots(Tab, Records, PrevSlot + 1).

%% Returns a list of all keys in table

all_nexts(Tab) ->
    FirstKey = mnesia:ec_first(Tab),
    all_nexts(Tab, FirstKey).

all_nexts(_Tab, '$end_of_table') ->
    [];
all_nexts(Tab, PrevKey) ->
    Key = mnesia:ec_next(Tab, PrevKey),
    [PrevKey] ++ all_nexts(Tab, Key).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

update_trans(Tab, Key, Acc) ->
    Update =
        fun() ->
           Res = catch mnesia:read({Tab, Key}),
           case Res of
               [{Tab, Key, Extra, Acc}] ->
                   Meta =
                       {mnesia:table_info(Tab, where_to_commit),
                        mnesia:table_info(Tab, commit_work)},
                   mnesia:write({Tab, Key, [Meta | Extra], Acc + 1});
               Val -> {read, Val, {acc, Acc}}
           end
        end,
    receive
        {Pid, quit} ->
            Pid ! {self(), Acc}
    after 3 ->
        case catch mnesia:sync_ec(Update) of
            ok ->
                update_trans(Tab, Key, Acc + 1);
            Else ->
                ?error("ec Operation failed on ~p (update no ~p) with ~p~nInfo w2read "
                       "~p w2write ~p w2commit ~p storage ~p ~n",
                       [node(),
                        Acc,
                        Else,
                        mnesia:table_info(Tab, where_to_read),
                        mnesia:table_info(Tab, where_to_write),
                        mnesia:table_info(Tab, where_to_commit),
                        mnesia:table_info(Tab, storage_type)])
        end
    end.

del_table_copy_1(suite) ->
    [];
del_table_copy_1(Config) when is_list(Config) ->
    [_Node1, Node2, _Node3] = Nodes = ?acquire_nodes(3, Config),
    del_table(Node2, Node2, Nodes). %Called on same Node as deleted

del_table_copy_2(suite) ->
    [];
del_table_copy_2(Config) when is_list(Config) ->
    [Node1, Node2, _Node3] = Nodes = ?acquire_nodes(3, Config),
    del_table(Node1, Node2, Nodes). %Called from other Node

del_table_copy_3(suite) ->
    [];
del_table_copy_3(Config) when is_list(Config) ->
    [_Node1, Node2, Node3] = Nodes = ?acquire_nodes(3, Config),
    del_table(Node3, Node2, Nodes). %Called from Node w.o. table

del_table(CallFrom, DelNode, [Node1, Node2, Node3]) ->
    Tab = schema_ops,
    Def = [{disc_only_copies, [Node1]},
           {ram_copies, [Node2]},
           {attributes, [key, attr1, attr2]}],
    ?log("Test case removing table from ~w, with ~w~n", [DelNode, Def]),
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),
    insert(Tab, 1000),

    Pid1 = spawn_link(Node1, ?MODULE, update_trans, [Tab, 1, 0]),
    Pid2 = spawn_link(Node2, ?MODULE, update_trans, [Tab, 2, 0]),
    Pid3 = spawn_link(Node3, ?MODULE, update_trans, [Tab, 3, 0]),

    dbg:tracer(process, {fun(Msg, _) -> tracer(Msg) end, void}),
    %%    dbg:n(Node2),
    %%    dbg:n(Node3),
    %% dbg:tp('_', []),
    %% dbg:tpl(dets, [timestamp]),
    dbg:p(Pid1, [m, c, timestamp]),

    ?match({atomic, ok}, rpc:call(CallFrom, mnesia, del_table_copy, [Tab, DelNode])),

    Pid1 ! {self(), quit},
    R1 = receive
             {Pid1, Res1} ->
                 Res1
         after 5000 ->
             io:format("~p~n", [process_info(Pid1)]),
             error
         end,
    Pid2 ! {self(), quit},
    R2 = receive
             {Pid2, Res2} ->
                 Res2
         after 5000 ->
             error
         end,
    Pid3 ! {self(), quit},
    R3 = receive
             {Pid3, Res3} ->
                 Res3
         after 5000 ->
             error
         end,
    verify_oids(Tab, Node1, Node2, Node3, R1, R2, R3),
    ?verify_mnesia([Node1, Node2, Node3], []).

tracer({trace_ts, _, send, Msg, Pid, {_, S, Ms}}) ->
    io:format("~p:~p ~p >> ~w ~n", [S, Ms, Pid, Msg]);
tracer({trace_ts, _, 'receive', Msg, {_, S, Ms}}) ->
    io:format("~p:~p << ~w ~n", [S, Ms, Msg]);
tracer(Msg) ->
    io:format("UMsg ~p ~n", [Msg]),
    ok.

add_table_copy_1(suite) ->
    [];
add_table_copy_1(Config) when is_list(Config) ->
    [Node1, Node2, Node3] = Nodes = ?acquire_nodes(3, Config),
    Def = [{ram_copies, [Node1, Node2]}, {attributes, [key, attr1, attr2]}],
    add_table(Node1, Node3, Nodes, Def).

%% Not so much diff from 1 but I got a feeling of a bug
%% should behave exactly the same but just checking the internal ordering
add_table_copy_2(suite) ->
    [];
add_table_copy_2(Config) when is_list(Config) ->
    [Node1, Node2, Node3] = Nodes = ?acquire_nodes(3, Config),
    Def = [{ram_copies, [Node1, Node2]}, {attributes, [key, attr1, attr2]}],
    add_table(Node2, Node3, Nodes, Def).

add_table_copy_3(suite) ->
    [];
add_table_copy_3(Config) when is_list(Config) ->
    [Node1, Node2, Node3] = Nodes = ?acquire_nodes(3, Config),
    Def = [{ram_copies, [Node1, Node2]}, {attributes, [key, attr1, attr2]}],
    add_table(Node3, Node3, Nodes, Def).

add_table_copy_4(suite) ->
    [];
add_table_copy_4(Config) when is_list(Config) ->
    [Node1, Node2, Node3] = Nodes = ?acquire_nodes(3, Config),
    Def = [{disc_only_copies, [Node1]}, {attributes, [key, attr1, attr2]}],
    add_table(Node2, Node3, Nodes, Def).

add_table(CallFrom, AddNode, [Node1, Node2, Node3], Def) ->
    ?log("Test case adding table at ~w, with ~w~n", [AddNode, Def]),
    Tab = schema_ops,
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),
    insert(Tab, 1002),

    Pid1 = spawn_link(Node1, ?MODULE, update_trans, [Tab, 1, 0]),
    Pid2 = spawn_link(Node2, ?MODULE, update_trans, [Tab, 2, 0]),
    Pid3 = spawn_link(Node3, ?MODULE, update_trans, [Tab, 3, 0]),

    ?match({atomic, ok},
           rpc:call(CallFrom, mnesia, add_table_copy, [Tab, AddNode, ram_copies])),
    Pid1 ! {self(), quit},
    R1 = receive
             {Pid1, Res1} ->
                 Res1
         after 5000 ->
             error
         end,
    Pid2 ! {self(), quit},
    R2 = receive
             {Pid2, Res2} ->
                 Res2
         after 5000 ->
             error
         end,
    Pid3 ! {self(), quit},
    R3 = receive
             {Pid3, Res3} ->
                 Res3
         after 5000 ->
             error
         end,
    verify_oids(Tab, Node1, Node2, Node3, R1, R2, R3),
    ?verify_mnesia([Node1, Node2, Node3], []).

move_table_copy_1(suite) ->
    [];
move_table_copy_1(Config) when is_list(Config) ->
    [Node1, Node2, Node3] = Nodes = ?acquire_nodes(3, Config),
    Def = [{ram_copies, [Node1, Node2]}, {attributes, [key, attr1, attr2]}],
    move_table(Node1, Node1, Node3, Nodes, Def).

move_table_copy_2(suite) ->
    [];
move_table_copy_2(Config) when is_list(Config) ->
    [Node1, Node2, Node3] = Nodes = ?acquire_nodes(3, Config),
    Def = [{ram_copies, [Node1, Node2]}, {attributes, [key, attr1, attr2]}],
    move_table(Node2, Node1, Node3, Nodes, Def).

move_table_copy_3(suite) ->
    [];
move_table_copy_3(Config) when is_list(Config) ->
    [Node1, Node2, Node3] = Nodes = ?acquire_nodes(3, Config),
    Def = [{ram_copies, [Node1, Node2]}, {attributes, [key, attr1, attr2]}],
    move_table(Node3, Node1, Node3, Nodes, Def).

move_table_copy_4(suite) ->
    [];
move_table_copy_4(Config) when is_list(Config) ->
    [Node1, Node2, Node3] = Nodes = ?acquire_nodes(3, Config),
    Def = [{ram_copies, [Node1]}, {attributes, [key, attr1, attr2]}],
    move_table(Node2, Node1, Node3, Nodes, Def).

move_table(CallFrom, FromNode, ToNode, [Node1, Node2, Node3], Def) ->
    ?log("Test case move table from ~w to ~w, with ~w~n", [FromNode, ToNode, Def]),
    Tab = schema_ops,
    ?match({atomic, ok}, mnesia:create_table(Tab, Def)),
    insert(Tab, 1002),

    Pid1 = spawn_link(Node1, ?MODULE, update_trans, [Tab, 1, 0]),
    Pid2 = spawn_link(Node2, ?MODULE, update_trans, [Tab, 2, 0]),
    Pid3 = spawn_link(Node3, ?MODULE, update_trans, [Tab, 3, 0]),

    ?match({atomic, ok},
           rpc:call(CallFrom, mnesia, move_table_copy, [Tab, FromNode, ToNode])),
    Pid1 ! {self(), quit},
    R1 = receive
             {Pid1, Res1} ->
                 Res1
         after 5000 ->
             ?error("timeout pid1~n", [])
         end,
    Pid2 ! {self(), quit},
    R2 = receive
             {Pid2, Res2} ->
                 Res2
         after 5000 ->
             ?error("timeout pid2~n", [])
         end,
    Pid3 ! {self(), quit},
    R3 = receive
             {Pid3, Res3} ->
                 Res3
         after 5000 ->
             ?error("timeout pid3~n", [])
         end,
    verify_oids(Tab, Node1, Node2, Node3, R1, R2, R3),
    ?verify_mnesia([Node1, Node2, Node3], []).

% Verify consistency between different nodes
% Due to limitations in the current ec_ops this can wrong from time to time!
verify_oids(Tab, N1, N2, N3, R1, R2, R3) ->
    io:format("DEBUG 1=>~p 2=>~p 3=>~p~n", [R1, R2, R3]),
    {info, _, _} = rpc:call(N1, mnesia_tm, get_info, [2000]),
    {info, _, _} = rpc:call(N2, mnesia_tm, get_info, [2000]),
    {info, _, _} = rpc:call(N3, mnesia_tm, get_info, [2000]),

    ?match([{_, _, _, R1}], rpc:call(N1, mnesia, ec_read, [{Tab, 1}])),
    ?match([{_, _, _, R1}], rpc:call(N2, mnesia, ec_read, [{Tab, 1}])),
    ?match([{_, _, _, R1}], rpc:call(N3, mnesia, ec_read, [{Tab, 1}])),
    ?match([{_, _, _, R2}], rpc:call(N1, mnesia, ec_read, [{Tab, 2}])),
    ?match([{_, _, _, R2}], rpc:call(N2, mnesia, ec_read, [{Tab, 2}])),
    ?match([{_, _, _, R2}], rpc:call(N3, mnesia, ec_read, [{Tab, 2}])),
    ?match([{_, _, _, R3}], rpc:call(N1, mnesia, ec_read, [{Tab, 3}])),
    ?match([{_, _, _, R3}], rpc:call(N2, mnesia, ec_read, [{Tab, 3}])),
    ?match([{_, _, _, R3}], rpc:call(N3, mnesia, ec_read, [{Tab, 3}])).

insert(_Tab, 0) ->
    ok;
insert(Tab, N) when N > 0 ->
    ok =
        mnesia:sync_ec(fun() ->
                          false = mnesia:is_transaction(),
                          mnesia:write({Tab, N, [], 0})
                       end),
    insert(Tab, N - 1).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% start_node(NodeName) ->
%     Prog = "../../../bin/erl ",
%     Args = "-pa " ++ filename:dirname(code:which(inet_tcp_proxy))
%     ++ " -name " ++ NodeName
%     ++ " -setcookie " ++ erlang:get_cookie()
%     ++ " -mnesia debug debug dir 'priv/b'"
%     ++ " -proto_dist inet_tcp_proxy",
%     Pid = erlang:open_port({spawn, Prog ++ Args}, []),
