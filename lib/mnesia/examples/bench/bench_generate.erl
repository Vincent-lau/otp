%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2001-2016. All Rights Reserved.
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
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% File    : bench_generate.hrl
%%% Author  : Hakan Mattsson <hakan@cslab.ericsson.se>
%%% Purpose : Start request generators and collect statistics
%%% Created : 21 Jun 2001 by Hakan Mattsson <hakan@cslab.ericsson.se>
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-module(bench_generate).

-author('hakan@cslab.ericsson.se').
-author('sl955@cam.ac.uk').

-include("bench.hrl").

%% Public
-export([start/1]).
%% Internal
-export([monitor_init/2, generator_init/2, worker_init/1]).

-record(prev_commits, {t1 = 0, t2 = 0, t3 = 0, t4 = 0, t5 = 0, ping = 0}).

-type workload() :: t1 | t2 | t3 | t4 | t5 | ping.

-record(tps,
        {t1 = [], t2 = [], t3 = [], t4 = [], t5 = [], ping = [], prev_commits = #prev_commits{}}).

-type tps() :: #tps{}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% The traffic generator
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% -------------------------------------------------------------------
%% Start request generators
%% -------------------------------------------------------------------

start(C) when is_record(C, config) ->
    MonPid = spawn_link(?MODULE, monitor_init, [C, self()]),
    receive
        {'EXIT', MonPid, Reason} ->
            exit(Reason);
        {monitor_done, MonPid, Res} ->
            Res
    end.

monitor_init(C, Parent) when is_record(C, config) ->
    process_flag(trap_exit, true),
    %% net_kernel:monitor_nodes(true), %% BUGBUG: Needed in order to re-start generators
    Nodes = C#config.generator_nodes,
    PerNode = C#config.n_generators_per_node,
    Timer = C#config.generator_warmup,
    ?d("~n", []),
    ?d("Start ~p request generators each at ~p nodes...~n", [PerNode, length(Nodes)]),
    ?d("~n", []),
    warmup_sticky(C),
    ?d("    ~p seconds warmup...~n", [Timer div 1000]),
    Alive = spawn_generators(C, Nodes, PerNode),
    erlang:send_after(Timer, self(), warmup_done),
    monitor_loop(C, Parent, Alive, []).

spawn_generators(C, Nodes, PerNode) ->
    [spawn_link(Node, ?MODULE, generator_init, [self(), C])
     || Node <- Nodes, _ <- lists:seq(1, PerNode)].

warmup_sticky(C) ->
    %% Select one node per fragment as master node
    Tabs = [subscriber, session, server, suffix],
    Fun = fun(S) ->
             {[Node | _], _, Wlock} = nearest_node(S, transaction, C),
             Stick = fun() -> [mnesia:read({T, S}, S, Wlock) || T <- Tabs] end,
             Mod = case C#config.activity of
                       async_ec -> mnesia_ec;
                       _ -> mnesia_frag
                   end,
             Args = [transaction, Stick, [], Mod],
             rpc:call(Node, mnesia, activity, Args)
          end,
    Suffixes = lists:seq(0, C#config.n_fragments - 1), % Assume even distrib.
    lists:foreach(Fun, Suffixes).

%% Main loop for benchmark monitor
monitor_loop(C, Parent, Alive, Deceased) ->
    receive
        warmup_done ->
            multicall(Alive, reset_statistics),
            display_table_stats(C, [subscriber]),
            Timer = C#config.generator_duration,
            ?d("    ~p seconds actual benchmarking...~n", [Timer div 1000]),
            spawn_partitioner(C),
            erlang:send_after(Timer, self(), measurement_done),
            monitor_loop(C, Parent, Alive, Deceased);
        measurement_done ->
            Stats = multicall(Alive, get_statistics),
            Timer = C#config.generator_cooldown,
            ?d("    ~p seconds cooldown...~n", [Timer div 1000]),
            erlang:send_after(Timer, self(), {cooldown_done, Stats}),
            monitor_loop(C, Parent, Alive, Deceased);
        {cooldown_done, Stats} ->
            multicall(Alive, stop),
            display_statistics(Stats, C),
            Parent ! {monitor_done, self(), ok},
            unlink(Parent),
            exit(monitor_done);
        {nodedown, _Node} ->
            monitor_loop(C, Parent, Alive, Deceased);
        {nodeup, Node} ->
            NeedsBirth = [N || N <- Deceased, N == Node],
            Born = spawn_generators(C, NeedsBirth, 1),
            monitor_loop(C, Parent, Born ++ Alive, Deceased -- NeedsBirth);
        {'EXIT', Pid, Reason} when Pid == Parent ->
            exit(Reason);
        {'EXIT', Pid, Reason} ->
            case lists:member(Pid, Alive) of
                true ->
                    ?d("Generator on node ~p died: ~p~n", [node(Pid), Reason]),
                    monitor_loop(C, Parent, Alive -- [Pid], [node(Pid) | Deceased]);
                false ->
                    monitor_loop(C, Parent, Alive, Deceased)
            end
    end.

%% Send message to a set of processes and wait for their replies
multicall(Pids, Message) ->
    Send =
        fun(Pid) ->
           Ref = erlang:monitor(process, Pid),
           Pid ! {self(), Ref, Message},
           {Pid, Ref}
        end,
    PidRefs = lists:map(Send, Pids),
    Collect =
        fun({Pid, Ref}) ->
           receive
               {'DOWN', Ref, process, Pid, Reason} -> {Pid, {'EXIT', Reason}};
               {Pid, Ref, Reply} ->
                   erlang:demonitor(Ref),
                   {Pid, Reply}
           end
        end,
    lists:map(Collect, PidRefs).

periodic_stats_watcher({table, Tab} = Counters) ->
    receive
        tp_change ->
            NCs = ets:match(Tab, {{'$1', n_commits, '$2'}, '$3'}),
            lists:foreach(fun([Type, Node, NC]) ->
                             [{{Type, tps, Node}, TPS = #tps{}}] =
                                 ets:lookup(Tab, {Type, tps, Node}),
                             NewTPS = update_tps(Type, TPS, NC),
                             ets:insert(Tab, {{Type, tps, Node}, NewTPS})
                          end,
                          NCs),
            erlang:send_after(1000, self(), tp_change),
            periodic_stats_watcher(Counters)
    end.

spawn_partitioner(C)
    when C#config.partition_time > 0 andalso length(C#config.table_nodes) > 2 
    andalso C#config.start_module =:= port ->
    Pid = spawn_link(fun() -> network_partitioner(C) end),
    Nodes = C#config.table_nodes,
    From = hd(Nodes),
    To = lists:nth(
             rand:uniform(length(Nodes) - 1), tl(Nodes)),
    erlang:send_after(rand:uniform(C#config.generator_duration - C#config.partition_time),
                      Pid,
                      {partition, From, To});
spawn_partitioner(_) ->
    ok.

network_partitioner(C) ->
    receive
        {partition, From, To} ->
            ?d("Partitioning network from ~p to ~p ~n", [From, To]),
            spawn(From, fun() -> ok = inet_tcp_proxy_dist:block(To) end),
            erlang:send_after(C#config.partition_time, self(), {recover, From, To}),
            network_partitioner(C);
        {recover, From, To} ->
            ?d("Recovering network from ~p to ~p ~n", [From, To]),
            spawn(From, inet_tcp_proxy_dist, allow, [To]),
            network_partitioner(C)
    end.

-spec update_tps(workload(), tps(), non_neg_integer()) -> tps().
update_tps(t1, TPS = #tps{t1 = T1, prev_commits = PC = #prev_commits{t1 = PT1}}, NC) ->
    TPS#tps{t1 = T1 ++ [NC - PT1], prev_commits = PC#prev_commits{t1 = NC}};
update_tps(t2, TPS = #tps{t2 = T2, prev_commits = PC = #prev_commits{t2 = PT2}}, NC) ->
    TPS#tps{t2 = T2 ++ [NC - PT2], prev_commits = PC#prev_commits{t2 = NC}};
update_tps(t3, TPS = #tps{t3 = T3, prev_commits = PC = #prev_commits{t3 = PT3}}, NC) ->
    TPS#tps{t3 = T3 ++ [NC - PT3], prev_commits = PC#prev_commits{t3 = NC}};
update_tps(t4, TPS = #tps{t4 = T4, prev_commits = PC = #prev_commits{t4 = PT4}}, NC) ->
    TPS#tps{t4 = T4 ++ [NC - PT4], prev_commits = PC#prev_commits{t4 = NC}};
update_tps(t5, TPS = #tps{t5 = T5, prev_commits = PC = #prev_commits{t5 = PT5}}, NC) ->
    TPS#tps{t5 = T5 ++ [NC - PT5], prev_commits = PC#prev_commits{t5 = NC}};
update_tps(ping,
           TPS = #tps{ping = Ping, prev_commits = PC = #prev_commits{ping = PPing}},
           NC) ->
    TPS#tps{ping = Ping ++ [NC - PPing], prev_commits = PC#prev_commits{ping = NC}}.

%% Initialize a traffic generator
generator_init(Monitor, C) ->
    process_flag(trap_exit, true),
    Tables = mnesia:system_info(tables),
    ok = mnesia:wait_for_tables(Tables, infinity),
    rand:seed(exsplus),
    Counters = reset_counters(C, C#config.statistics_detail),
    SessionTab = ets:new(bench_sessions, [public, {keypos, 1}]),
    case C#config.statistics_detail of
        debug_tp ->
            WatcherPid = spawn_link(fun() -> periodic_stats_watcher(Counters) end),
            erlang:send_after(1000, WatcherPid, tp_change);
        _ ->
            ok
    end,
    generator_loop(Monitor, C, SessionTab, Counters).

%% Main loop for traffic generator
-spec generator_loop(_,
                     #config{},
                     atom() | ets:tid(),
                     {table, _} |
                     {integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}) ->
                        no_return().
generator_loop(Monitor, C, SessionTab, Counters) ->
    receive
        {ReplyTo, Ref, get_statistics} ->
            Stats = get_counters(C, Counters),
            ReplyTo ! {self(), Ref, Stats},
            generator_loop(Monitor, C, SessionTab, Counters);
        {ReplyTo, Ref, reset_statistics} ->
            Stats = get_counters(C, Counters),
            Counters2 = reset_counters(C, Counters),
            ReplyTo ! {self(), Ref, Stats},
            generator_loop(Monitor, C, SessionTab, Counters2);
        {_ReplyTo, _Ref, stop} ->
            exit(shutdown);
        {'EXIT', Pid, Reason} when Pid == Monitor ->
            exit(Reason);
        {'EXIT', Pid, Reason} ->
            Node = node(Pid),
            ?d("Worker on node ~p(~p) died: ~p~n", [Node, node(), Reason]),
            Key = {worker, Node},
            case get(Key) of
                undefined ->
                    ignore;
                Pid ->
                    erase(Key);
                _ ->
                    ignore
            end,
            generator_loop(Monitor, C, SessionTab, Counters)
    after 0 ->
        {Name, {Nodes, Activity, Wlock}, Fun, CommitSessions} = gen_traffic(C, SessionTab),
        Mod = case C#config.activity of
                  async_dirty ->
                      mnesia;
                  async_ec ->
                      mnesia;
                  transaction ->
                      mnesia_frag
              end,
        Before = erlang:monotonic_time(),
        Res = call_worker(Nodes, Activity, Fun, Wlock, Mod),
        After = erlang:monotonic_time(),
        Elapsed = elapsed(Before, After),
        post_eval(Monitor, C, Elapsed, Res, Name, CommitSessions, SessionTab, Counters)
    end.

%% Perform a transaction on a node near the data
call_worker([Node | _], async_ec, Fun, Wlock, _Mod) when Node =:= node() ->
    {Node, catch mnesia:activity(async_ec, Fun, [Wlock], mnesia_ec)};
call_worker([Node | _], Activity, Fun, Wlock, Mod) when Node =:= node() ->
    {Node, catch mnesia:activity(Activity, Fun, [Wlock], Mod)};
call_worker([Node | _] = Nodes, Activity, Fun, Wlock, Mod) ->
    Key = {worker, Node},
    case get(Key) of
        Pid when is_pid(Pid) ->
            Args = [Activity, Fun, [Wlock], Mod],
            Pid ! {activity, self(), Args},
            receive
                {'EXIT', Pid, Reason} ->
                    ?d("Worker on node ~p(~p) died: ~p~n", [Node, node(), Reason]),
                    erase(Key),
                    retry_worker(Nodes, Activity, Fun, Wlock, Mod, {'EXIT', Reason});
                {activity_result, Pid, Result} ->
                    case Result of
                        {'EXIT', {aborted, {not_local, _}}} ->
                            retry_worker(Nodes, Activity, Fun, Wlock, Mod, Result);
                        _ ->
                            {Node, Result}
                    end
            end;
        undefined ->
            GenPid = self(),
            Pid = spawn_link(Node, ?MODULE, worker_init, [GenPid]),
            put(Key, Pid),
            call_worker(Nodes, Activity, Fun, Wlock, Mod)
    end.

retry_worker([], _Activity, _Fun, _Wlock, _Mod, Reason) ->
    {node(), Reason};
retry_worker([BadNode | SpareNodes], Activity, Fun, Wlock, Mod, Reason) ->
    Nodes = SpareNodes -- [BadNode],
    case Nodes of
        [] ->
            {BadNode, Reason};
        [_] ->
            call_worker(Nodes, Activity, Fun, write, Mod);
        _ ->
            call_worker(Nodes, Activity, Fun, Wlock, Mod)
    end.

worker_init(Parent) ->
    Tables = mnesia:system_info(tables),
    ok = mnesia:wait_for_tables(Tables, infinity),
    worker_loop(Parent).

%% Main loop for remote workers
worker_loop(Parent) ->
    receive
        {activity, Parent, [Activity, Fun, Extra, Mod]} ->
            Result = catch mnesia:activity(Activity, Fun, Extra, Mod),
            Parent ! {activity_result, self(), Result},
            worker_loop(Parent)
    end.

elapsed(Before, After) ->
    erlang:convert_time_unit(After - Before, native, micro_seconds).

%% Lookup counters
get_counters(_C, {table, Tab}) ->
    ets:match_object(Tab, '_');
get_counters(_C, {NM, NC, NA, NB}) ->
    Trans = any,
    Node = somewhere,
    [{{Trans, n_micros, Node}, NM},
     {{Trans, n_commits, Node}, NC},
     {{Trans, n_aborts, Node}, NA},
     {{Trans, n_branches_executed, Node}, NB}];
get_counters(_C, {NM, NC, NA, NB, TPS, Latencies}) ->
    Trans = any,
    Node = somewhere,
    [{{Trans, n_micros, Node}, NM},
     {{Trans, n_commits, Node}, NC},
     {{Trans, n_aborts, Node}, NA},
     {{Trans, n_branches_executed, Node}, NB},
     {{Trans, tps, Node}, TPS},
     {{Trans, latency, Node}, Latencies}].

% Clear all counters
reset_counters(_C, normal) ->
    {0, 0, 0, 0};
reset_counters(C, {_, _, _, _}) ->
    reset_counters(C, normal);
reset_counters(C, debug) ->
    CounterTab = ets:new(bench_pending, [public, {keypos, 1}]),
    reset_counters(C, {table, CounterTab});
reset_counters(C, debug2) ->
    CounterTab = ets:new(bench_pending, [public, {keypos, 1}]),
    reset_counters(C, {table, CounterTab});
reset_counters(C, debug_tp) ->
    CounterTab = ets:new(bench_pending, [public, {keypos, 1}]),
    reset_counters(C, {table, CounterTab});
reset_counters(C, debug_latency) ->
    CounterTab = ets:new(bench_pending, [public, {keypos, 1}]),
    reset_counters(C, {table, CounterTab});
reset_counters(C, {table, Tab} = Counters) ->
    Names = [n_micros, n_commits, n_aborts, n_branches_executed],
    Nodes = C#config.generator_nodes ++ C#config.table_nodes,
    TransTypes = [t1, t2, t3, t4, t5, ping],
    [ets:insert(Tab, {{Trans, Name, Node}, 0})
     || Name <- Names, Node <- Nodes, Trans <- TransTypes],
    [ets:insert(Tab, {{Trans, tps, Node}, #tps{}}) || Node <- Nodes, Trans <- TransTypes],
    QE = init_quantile_estimator(C),
    [ets:insert(Tab, {{Trans, latency, Node}, QE}) || Node <- Nodes, Trans <- TransTypes],
    Counters.

init_quantile_estimator(C) when C#config.statistics_detail =:= debug_latency ->
    IV = quantile_estimator:f_targeted([{0.99, 0.005}]),
    quantile_estimator:new(IV);
init_quantile_estimator(_C) ->
    0.

%% Determine the outcome of a transaction and increment the counters
post_eval(Monitor,
          C,
          Elapsed,
          {Node, Res},
          Name,
          CommitSessions,
          SessionTab,
          {table, Tab} = Counters) ->
    case Res of
        {do_commit, BranchExecuted, _} ->
            incr(Tab, {Name, n_micros, Node}, Elapsed),
            incr(Tab, {Name, n_commits, Node}, 1),
            add_latency(C, Tab, {Name, latency, Node}, Elapsed),
            case BranchExecuted of
                true ->
                    incr(Tab, {Name, n_branches_executed, Node}, 1),
                    commit_session(CommitSessions),
                    generator_loop(Monitor, C, SessionTab, Counters);
                false ->
                    generator_loop(Monitor, C, SessionTab, Counters)
            end;
        {'EXIT', {aborted, {do_rollback, BranchExecuted, _}}} ->
            incr(Tab, {Name, n_micros, Node}, Elapsed),
            incr(Tab, {Name, n_aborts, Node}, 1),
            case BranchExecuted of
                true ->
                    incr(Tab, {Name, n_branches_executed, Node}, 1),
                    generator_loop(Monitor, C, SessionTab, Counters);
                false ->
                    generator_loop(Monitor, C, SessionTab, Counters)
            end;
        {'EXIT', {aborted, {busy_read, _, _}}} ->
            incr(Tab, {Name, n_micros, Node}, Elapsed),
            incr(Tab, {Name, n_aborts, Node}, 1),
            generator_loop(Monitor, C, SessionTab, Counters);
        _ ->
            ?d("Failed(~p): ~p~n", [Node, Res]),
            incr(Tab, {Name, n_micros, Node}, Elapsed),
            incr(Tab, {Name, n_aborts, Node}, 1),
            generator_loop(Monitor, C, SessionTab, Counters)
    end;
post_eval(Monitor,
          C,
          Elapsed,
          {_Node, Res},
          _Name,
          CommitSessions,
          SessionTab,
          {NM, NC, NA, NB}) ->
    case Res of
        {do_commit, BranchExecuted, _} ->
            case BranchExecuted of
                true ->
                    commit_session(CommitSessions),
                    generator_loop(Monitor, C, SessionTab, {NM + Elapsed, NC + 1, NA, NB + 1});
                false ->
                    generator_loop(Monitor, C, SessionTab, {NM + Elapsed, NC + 1, NA, NB})
            end;
        {'EXIT', {aborted, {do_rollback, BranchExecuted, _}}} ->
            case BranchExecuted of
                true ->
                    generator_loop(Monitor, C, SessionTab, {NM + Elapsed, NC, NA + 1, NB + 1});
                false ->
                    generator_loop(Monitor, C, SessionTab, {NM + Elapsed, NC, NA + 1, NB})
            end;
        _ ->
            ?d("Failed: ~p~n", [Res]),
            generator_loop(Monitor, C, SessionTab, {NM + Elapsed, NC, NA + 1, NB})
    end.

add_latency(C, Tab, Counter, Elapsed) when C#config.statistics_detail =:= debug_latency ->
    case ets:lookup(Tab, Counter) of
        [{Counter, QE1}] ->
            QE2 = quantile_estimator:insert(Elapsed, QE1),
            ets:insert(Tab, {Counter, QE2})
    end;
add_latency(_C, _Tab, _Counter, _Elapsed) ->
    ignore.

incr(Tab, Counter, Incr) ->
    ets:update_counter(Tab, Counter, Incr).

commit_session(no_fun) ->
    ignore;
commit_session(Fun) when is_function(Fun, 0) ->
    Fun().

%% Randlomly choose a transaction type according to benchmark spec
gen_traffic(C, SessionTab)
    when C#config.activity =:= transaction, C#config.generator_profile == random ->
    case rand:uniform(100) of
        Rand when Rand > 0, Rand =< 25 ->
            gen_t1(C, SessionTab);
        Rand when Rand > 25, Rand =< 50 ->
            gen_t2(C, SessionTab);
        Rand when Rand > 50, Rand =< 70 ->
            gen_t3(C, SessionTab);
        Rand when Rand > 70, Rand =< 85 ->
            gen_t4(C, SessionTab);
        Rand when Rand > 85, Rand =< 100 ->
            gen_t5(C, SessionTab)
    end;
gen_traffic(C, SessionTab)
    when (C#config.activity =:= async_ec orelse C#config.activity =:= async_dirty)
         andalso C#config.generator_profile =:= random ->
    Activity = C#config.activity,
    case rand:uniform(100) of
        Rand when Rand > 0, Rand =< 25 ->
            gen_async1(C, SessionTab, Activity);
        Rand when Rand > 25, Rand =< 50 ->
            gen_async2(C, SessionTab, Activity);
        Rand when Rand > 50, Rand =< 70 ->
            gen_async3(C, SessionTab, Activity);
        Rand when Rand > 70, Rand =< 85 ->
            gen_async4(C, SessionTab, Activity);
        Rand when Rand > 85, Rand =< 100 ->
            gen_async5(C, SessionTab, Activity)
    end;
gen_traffic(C, SessionTab)
    when C#config.activity =:= transaction andalso C#config.generator_profile =:= rw_ratio ->
    ReadPct = C#config.rw_ratio * 100,
    case rand:uniform(100) of
        Rand when Rand > 0, Rand =< ReadPct ->
            gen_t2(C, SessionTab);
        Rand when Rand > ReadPct ->
            gen_t1(C, SessionTab)
    end;
gen_traffic(C, SessionTab)
    when (C#config.activity =:= async_ec orelse C#config.activity =:= async_dirty)
         andalso C#config.generator_profile =:= rw_ratio ->
    Activity = C#config.activity,
    ReadPct = C#config.rw_ratio * 100,
    case rand:uniform(100) of
        Rand when Rand > 0, Rand =< ReadPct ->
            gen_async2(C, SessionTab, Activity);
        Rand when Rand > ReadPct ->
            gen_async1(C, SessionTab, Activity)
    end;
gen_traffic(C, SessionTab) when C#config.activity =:= transaction ->
    case C#config.generator_profile of
        t1 ->
            gen_t1(C, SessionTab);
        t2 ->
            gen_t2(C, SessionTab);
        t3 ->
            gen_t3(C, SessionTab);
        t4 ->
            gen_t4(C, SessionTab);
        t5 ->
            gen_t5(C, SessionTab);
        ping ->
            gen_ping(C, SessionTab)
    end;
gen_traffic(C, SessionTab) when C#config.activity =:= async_dirty ->
    case C#config.generator_profile of
        t1 ->
            gen_async1(C, SessionTab, async_dirty);
        t2 ->
            gen_async2(C, SessionTab, async_dirty);
        t3 ->
            gen_async3(C, SessionTab, async_dirty);
        t4 ->
            gen_async4(C, SessionTab, async_dirty);
        t5 ->
            gen_async5(C, SessionTab, async_dirty)
    end;
gen_traffic(C, SessionTab) when C#config.activity =:= async_ec ->
    case C#config.generator_profile of
        t1 ->
            gen_async1(C, SessionTab, async_ec);
        t2 ->
            gen_async2(C, SessionTab, async_ec);
        t3 ->
            gen_async3(C, SessionTab, async_ec);
        t4 ->
            gen_async4(C, SessionTab, async_ec);
        t5 ->
            gen_async5(C, SessionTab, async_ec)
    end.

gen_async1(C, _SessionTab, AsyncAct)
    when AsyncAct =:= async_dirty orelse AsyncAct =:= async_ec ->
    SubscrId = rand:uniform(C#config.n_subscribers) - 1,
    SubscrKey = bench_async:number_to_key(SubscrId, C),
    Location = 4711,
    ChangedBy = <<4711:(8 * 25)>>,
    ChangedTime = <<4711:(8 * 25)>>,
    {t1,
     nearest_node(SubscrId, AsyncAct, C),
     fun(Wlock) ->
        bench_async:update_current_location(Wlock, SubscrKey, Location, ChangedBy, ChangedTime)
     end,
     no_fun}.

gen_async2(C, _SessionTab, AsyncAct)
    when AsyncAct =:= async_dirty orelse AsyncAct =:= async_ec ->
    SubscrId = rand:uniform(C#config.n_subscribers) - 1,
    SubscrKey = bench_async:number_to_key(SubscrId, C),
    {t2,
     nearest_node(SubscrId, AsyncAct, C),
     fun(Wlock) -> bench_async:read_current_location(Wlock, SubscrKey) end,
     no_fun}.

gen_async3(C, SessionTab, AsyncAct)
    when AsyncAct =:= async_dirty orelse AsyncAct =:= async_ec ->
    case ets:first(SessionTab) of
        '$end_of_table' ->
            %% This generator does not have any session,
            %% try reading someone elses session details
            SubscrId = rand:uniform(C#config.n_subscribers) - 1,
            SubscrKey = bench_async:number_to_key(SubscrId, C),
            ServerId = rand:uniform(C#config.n_servers) - 1,
            ServerBit = 1 bsl ServerId,
            {t3,
             nearest_node(SubscrId, AsyncAct, C),
             fun(Wlock) -> bench_async:read_session_details(Wlock, SubscrKey, ServerBit, ServerId)
             end,
             no_fun};
        {SubscrId, SubscrKey, ServerId} ->
            %% This generator do have a session,
            %% read its session details
            ServerBit = 1 bsl ServerId,
            {t3,
             nearest_node(SubscrId, AsyncAct, C),
             fun(Wlock) -> bench_async:read_session_details(Wlock, SubscrKey, ServerBit, ServerId)
             end,
             no_fun}
    end.

gen_async4(C, SessionTab, AsyncAct)
    when AsyncAct =:= async_dirty orelse AsyncAct =:= async_ec ->
    %% This generator may already have sessions,
    %% create a new session and hope that no other
    %% generator already has occupied it
    SubscrId = rand:uniform(C#config.n_subscribers) - 1,
    SubscrKey = bench_async:number_to_key(SubscrId, C),
    ServerId = rand:uniform(C#config.n_servers) - 1,
    ServerBit = 1 bsl ServerId,
    Details = <<4711:(8 * 2000)>>,
    DoRollback = rand:uniform(100) =< 2,
    Insert = fun() -> ets:insert(SessionTab, {{SubscrId, SubscrKey, ServerId}, self()}) end,
    {t4,
     nearest_node(SubscrId, AsyncAct, C),
     fun(Wlock) ->
        bench_async:create_session_to_server(Wlock,
                                             SubscrKey,
                                             ServerBit,
                                             ServerId,
                                             Details,
                                             DoRollback)
     end,
     Insert}.

gen_async5(C, SessionTab, AsyncAct)
    when AsyncAct =:= async_dirty orelse AsyncAct =:= async_ec ->
    case ets:first(SessionTab) of
        '$end_of_table' ->
            %% This generator does not have any session,
            %% try to delete someone elses session details
            SubscrId = rand:uniform(C#config.n_subscribers) - 1,
            SubscrKey = bench_async:number_to_key(SubscrId, C),
            ServerId = rand:uniform(C#config.n_servers) - 1,
            ServerBit = 1 bsl ServerId,
            DoRollback = rand:uniform(100) =< 2,
            {t5,
             nearest_node(SubscrId, AsyncAct, C),
             fun(Wlock) ->
                bench_async:delete_session_from_server(Wlock,
                                                       SubscrKey,
                                                       ServerBit,
                                                       ServerId,
                                                       DoRollback)
             end,
             no_fun};
        {SubscrId, SubscrKey, ServerId} ->
            %% This generator do have at least one session,
            %% delete it.
            ServerBit = 1 bsl ServerId,
            DoRollback = rand:uniform(100) =< 2,
            Delete = fun() -> ets:delete(SessionTab, {SubscrId, SubscrKey, ServerId}) end,
            {t5,
             nearest_node(SubscrId, AsyncAct, C),
             fun(Wlock) ->
                bench_async:delete_session_from_server(Wlock,
                                                       SubscrKey,
                                                       ServerBit,
                                                       ServerId,
                                                       DoRollback)
             end,
             Delete}
    end.

gen_t1(C, _SessionTab) ->
    SubscrId = rand:uniform(C#config.n_subscribers) - 1,
    SubscrKey = bench_trans:number_to_key(SubscrId, C),
    Location = 4711,
    ChangedBy = <<4711:(8 * 25)>>,
    ChangedTime = <<4711:(8 * 25)>>,
    {t1,
     nearest_node(SubscrId, transaction, C),
     fun(Wlock) ->
        bench_trans:update_current_location(Wlock, SubscrKey, Location, ChangedBy, ChangedTime)
     end,
     no_fun}.

gen_t2(C, _SessionTab) ->
    SubscrId = rand:uniform(C#config.n_subscribers) - 1,
    SubscrKey = bench_trans:number_to_key(SubscrId, C),
    {t2,
     nearest_node(SubscrId, sync_dirty, C),
     %%nearest_node(SubscrId, transaction, C),
     fun(Wlock) -> bench_trans:read_current_location(Wlock, SubscrKey) end,
     no_fun}.

gen_t3(C, SessionTab) ->
    case ets:first(SessionTab) of
        '$end_of_table' ->
            %% This generator does not have any session,
            %% try reading someone elses session details
            SubscrId = rand:uniform(C#config.n_subscribers) - 1,
            SubscrKey = bench_trans:number_to_key(SubscrId, C),
            ServerId = rand:uniform(C#config.n_servers) - 1,
            ServerBit = 1 bsl ServerId,
            {t3,
             nearest_node(SubscrId, transaction, C),
             fun(Wlock) -> bench_trans:read_session_details(Wlock, SubscrKey, ServerBit, ServerId)
             end,
             no_fun};
        {SubscrId, SubscrKey, ServerId} ->
            %% This generator do have a session,
            %% read its session details
            ServerBit = 1 bsl ServerId,
            {t3,
             nearest_node(SubscrId, transaction, C),
             fun(Wlock) -> bench_trans:read_session_details(Wlock, SubscrKey, ServerBit, ServerId)
             end,
             no_fun}
    end.

gen_t4(C, SessionTab) ->
    %% This generator may already have sessions,
    %% create a new session and hope that no other
    %% generator already has occupied it
    SubscrId = rand:uniform(C#config.n_subscribers) - 1,
    SubscrKey = bench_trans:number_to_key(SubscrId, C),
    ServerId = rand:uniform(C#config.n_servers) - 1,
    ServerBit = 1 bsl ServerId,
    Details = <<4711:(8 * 2000)>>,
    DoRollback = rand:uniform(100) =< 2,
    Insert = fun() -> ets:insert(SessionTab, {{SubscrId, SubscrKey, ServerId}, self()}) end,
    {t4,
     nearest_node(SubscrId, transaction, C),
     fun(Wlock) ->
        bench_trans:create_session_to_server(Wlock,
                                             SubscrKey,
                                             ServerBit,
                                             ServerId,
                                             Details,
                                             DoRollback)
     end,
     Insert}.

gen_t5(C, SessionTab) ->
    case ets:first(SessionTab) of
        '$end_of_table' ->
            %% This generator does not have any session,
            %% try to delete someone elses session details
            SubscrId = rand:uniform(C#config.n_subscribers) - 1,
            SubscrKey = bench_trans:number_to_key(SubscrId, C),
            ServerId = rand:uniform(C#config.n_servers) - 1,
            ServerBit = 1 bsl ServerId,
            DoRollback = rand:uniform(100) =< 2,
            {t5,
             nearest_node(SubscrId, transaction, C),
             fun(Wlock) ->
                bench_trans:delete_session_from_server(Wlock,
                                                       SubscrKey,
                                                       ServerBit,
                                                       ServerId,
                                                       DoRollback)
             end,
             no_fun};
        {SubscrId, SubscrKey, ServerId} ->
            %% This generator do have at least one session,
            %% delete it.
            ServerBit = 1 bsl ServerId,
            DoRollback = rand:uniform(100) =< 2,
            Delete = fun() -> ets:delete(SessionTab, {SubscrId, SubscrKey, ServerId}) end,
            {t5,
             nearest_node(SubscrId, transaction, C),
             fun(Wlock) ->
                bench_trans:delete_session_from_server(Wlock,
                                                       SubscrKey,
                                                       ServerBit,
                                                       ServerId,
                                                       DoRollback)
             end,
             Delete}
    end.

gen_ping(C, _SessionTab) ->
    SubscrId = rand:uniform(C#config.n_subscribers) - 1,
    {ping,
     nearest_node(SubscrId, transaction, C),
     fun(_Wlock) -> {do_commit, true, []} end,
     no_fun}.

%% Select a node as near as the subscriber data as possible
nearest_node(_SubscrId, Activity, C) when C#config.n_fragments == 1 ->
    {[node()], Activity, write};
nearest_node(SubscrId, Activity, C) ->
    Suffix = bench_trans:number_to_suffix(SubscrId),
    case mnesia_frag:table_info(t, s, {suffix, Suffix}, where_to_write) of
        [] ->
            {[node()], Activity, write};
        [Node] ->
            {[Node], Activity, write};
        Nodes ->
            Wlock = C#config.write_lock_type,
            if C#config.always_try_nearest_node; Wlock =:= write ->
                   case lists:member(node(), Nodes) of
                       true ->
                           {[node() | Nodes], Activity, Wlock};
                       false ->
                           Node = pick_node(Suffix, C, Nodes),
                           {[Node | Nodes], Activity, Wlock}
                   end;
               Wlock == sticky_write ->
                   Node = pick_node(Suffix, C, Nodes),
                   {[Node | Nodes], Activity, Wlock}
            end
    end.

pick_node(Suffix, C, Nodes) ->
    Ordered = lists:sort(Nodes),
    NumberOfActive = length(Ordered),
    PoolSize = length(C#config.table_nodes),
    Suffix2 =
        case PoolSize rem NumberOfActive of
            0 ->
                Suffix div (PoolSize div NumberOfActive);
            _ ->
                Suffix
        end,
    N = Suffix2 rem NumberOfActive + 1,
    lists:nth(N, Ordered).

display_statistics(Stats, C) ->
    GoodStats = [{node(GenPid), GenStats} || {GenPid, GenStats} <- Stats, is_list(GenStats)],
    FlatStats =
        [{Type, Name, EvalNode, GenNode, Count}
         || {GenNode, GenStats} <- GoodStats, {{Type, Name, EvalNode}, Count} <- GenStats],
    TotalStats = calc_stats_per_tag(lists:keysort(2, FlatStats), 2, []),
    % ?d("Total statistics: ~p~n", [TotalStats]),
    display_table_stats(C, [subscriber]),
    {value, {n_aborts, 0, NA, 0, 0, [], []}} =
        lists:keysearch(n_aborts, 1, TotalStats ++ [{n_aborts, 0, 0, 0, 0, [], []}]),
    {value, {n_commits, NC, 0, 0, 0, [], []}} =
        lists:keysearch(n_commits, 1, TotalStats ++ [{n_commits, 0, 0, 0, 0, [], []}]),
    {value, {n_branches_executed, 0, 0, _NB, 0, [], []}} =
        lists:keysearch(n_branches_executed,
                        1,
                        TotalStats ++ [{n_branches_executed, 0, 0, 0, 0, [], []}]),
    {value, {n_micros, 0, 0, 0, AccMicros, [], []}} =
        lists:keysearch(n_micros, 1, TotalStats ++ [{n_micros, 0, 0, 0, 0, [], []}]),
    {value, {tps, 0, 0, 0, 0, TPS, []}} =
        lists:keysearch(tps, 1, TotalStats ++ [{tps, 0, 0, 0, 0, [], []}]),
    {value, {latency, 0, 0, 0, 0, [], LATS}} =
        lists:keysearch(latency, 1, TotalStats ++ [{latency, 0, 0, 0, 0, [], []}]),
    NT = NA + NC,
    NG = length(GoodStats),
    NTN = length(C#config.table_nodes),
    WallMicros = C#config.generator_duration * 1000 * NG,
    Overhead = catch (WallMicros - AccMicros) / WallMicros,
    ?d("~n", []),
    ?d("Benchmark result...~n", []),
    ?d("~n", []),
    Kind =
        case C#config.activity of
            async_ec ->
                ec;
            async_dirty ->
                dirty;
            _Other ->
                transaction
        end,
    ?d("    ~p ~ps per second (TPS).~n", [catch NT * 1000000 * NG div AccMicros, Kind]),
    ?d("    ~p ~p commits per second against time~n", [TPS, Kind]),
    ?d("    ~p ~pPS per table node.~n",
       [catch NT * 1000000 * NG div (AccMicros * NTN), Kind]),
    ?d("    ~p micro seconds in average per ~p, including latency.~n",
       [Kind, catch AccMicros div NT]),
    ?d("    ~p 99th percentile latency ~p.~n", [Kind, LATS]),
    ?d("    ~p ~p. ~f% generator overhead.~n", [NT, Kind, Overhead * 100]),

    TypeStats = calc_stats_per_tag(lists:keysort(1, FlatStats), 1, []),
    EvalNodeStats = calc_stats_per_tag(lists:keysort(3, FlatStats), 3, []),
    GenNodeStats = calc_stats_per_tag(lists:keysort(4, FlatStats), 4, []),
    if C#config.statistics_detail == normal ->
           ignore;
       true ->
           ?d("~n", []),
           ?d("Statistics per ~p type...~n", [Kind]),
           ?d("~n", []),
           display_type_stats("    ", TypeStats, NT, AccMicros),

           ?d("~n", []),
           ?d("~p statistics per table node...~n", [Kind]),
           ?d("~n", []),
           display_calc_stats("    ", EvalNodeStats, NT, AccMicros),

           ?d("~n", []),
           ?d("~p statistics per generator node...~n", [Kind]),
           ?d("~n", []),
           display_calc_stats("    ", GenNodeStats, NT, AccMicros)
    end,
    if C#config.statistics_detail /= debug2 ->
           ignore;
       true ->
           io:format("~n", []),
           io:format("------ Test Results ------~n", []),
           io:format("Length        : ~p sec~n", [C#config.generator_duration div 1000]),
           Host = lists:nth(2, string:tokens(atom_to_list(node()), [$@])),
           io:format("Processor     : ~s~n", [Host]),
           io:format("Number of Proc: ~p~n", [NG]),
           io:format("~n", []),
           display_trans_stats("    ", TypeStats, NT, AccMicros, NG),
           io:format("~n", []),
           io:format("  Overall Statistics~n", []),
           io:format("     ~p: ~p~n", [Kind, NT]),
           io:format("     Inner       : ~p TPS~n", [catch NT * 1000000 * NG div AccMicros]),
           io:format("     Outer       : ~p TPS~n", [catch NT * 1000000 * NG div WallMicros]),
           io:format("~n", [])
    end.


display_table_stats(C, Tables) ->
    ?d("Table Stats...~n", []),
    ?d("~n", []),
    do_display_table_stats(C, Tables).

do_display_table_stats(_C, []) ->
    ok;
do_display_table_stats(C, [Tab | Tables]) ->
    {Bytes, []} = rpc:multicall(C#config.table_nodes, mnesia, table_info, [Tab, memory]),
    Bytes2 = [B * 4 || B <- Bytes],
    ?d("    ~p table size totally ~p bytes.~n", [Tab, Bytes2]),
    do_display_table_stats(C, Tables).


display_calc_stats(Prefix, [{_Tag, 0, 0, 0, 0, [], []} | Rest], NT, Micros) ->
    display_calc_stats(Prefix, Rest, NT, Micros);
display_calc_stats(Prefix, [{Tag, NC, NA, _NB, NM, _NCS, _Lats} | Rest], NT, Micros) ->
    ?d("~s~s n=~s%\ttime=~s%~n",
       [Prefix, left(Tag), percent(NC + NA, NT), percent(NM, Micros)]),
    display_calc_stats(Prefix, Rest, NT, Micros);
display_calc_stats(_, [], _, _) ->
    ok.

display_type_stats(Prefix, [{_Tag, 0, 0, 0, 0, _NCS, _Lats} | Rest], NT, Micros) ->
    display_type_stats(Prefix, Rest, NT, Micros);
display_type_stats(Prefix, [{Tag, NC, NA, NB, NM, _NCS, _Lats} | Rest], NT, Micros) ->
    ?d("~s~s n=~s%\ttime=~s%\tavg micros=~p~n",
       [Prefix, left(Tag), percent(NC + NA, NT), percent(NM, Micros), catch NM div (NC + NA)]),
    case NA /= 0 of
        true ->
            ?d("~s    ~s% aborted~n", [Prefix, percent(NA, NC + NA)]);
        false ->
            ignore
    end,
    case NB /= 0 of
        true ->
            ?d("~s    ~s% branches executed~n", [Prefix, percent(NB, NC + NA)]);
        false ->
            ignore
    end,
    display_type_stats(Prefix, Rest, NT, Micros);
display_type_stats(_, [], _, _) ->
    ok.

left(Term) ->
    string:left(
        lists:flatten(
            io_lib:format("~p", [Term])),
        27,
        $.).

percent(_Part, 0) ->
    "infinity";
percent(Part, Total) ->
    io_lib:format("~8.4f", [Part * 100 / Total]).

calc_stats_per_tag([], _Pos, Acc) ->
    lists:sort(Acc);
calc_stats_per_tag([Tuple | _] = FlatStats, Pos, Acc) when size(Tuple) == 5 ->
    Tag = element(Pos, Tuple),
    do_calc_stats_per_tag(FlatStats, Pos, {Tag, 0, 0, 0, 0, [], []}, Acc).

do_calc_stats_per_tag([Tuple | Rest], Pos, {Tag, NC, NA, NB, NM, NTPS, Lats}, Acc)
    when element(Pos, Tuple) == Tag ->
    Val = element(5, Tuple),
    case element(2, Tuple) of
        n_commits ->
            do_calc_stats_per_tag(Rest, Pos, {Tag, NC + Val, NA, NB, NM, [], Lats}, Acc);
        n_aborts ->
            do_calc_stats_per_tag(Rest, Pos, {Tag, NC, NA + Val, NB, NM, [], Lats}, Acc);
        n_branches_executed ->
            do_calc_stats_per_tag(Rest, Pos, {Tag, NC, NA, NB + Val, NM, [], Lats}, Acc);
        n_micros ->
            do_calc_stats_per_tag(Rest, Pos, {Tag, NC, NA, NB, NM + Val, [], Lats}, Acc);
        tps ->
            Type = element(1, Tuple),
            do_calc_stats_per_tag(Rest,
                                  Pos,
                                  {Tag, NC, NA, NB, NM, sum_tps(Type, Val, NTPS), Lats},
                                  Acc);
        latency ->
            Type = element(1, Tuple),
            do_calc_stats_per_tag(Rest,
                                  Pos,
                                  {Tag, NC, NA, NB, NM, [], latency99(Type, Val, Lats)},
                                  Acc)
    end;
do_calc_stats_per_tag(GenStats, Pos, CalcStats, Acc) ->
    calc_stats_per_tag(GenStats, Pos, [CalcStats | Acc]).

-spec make_equal_length([integer()], [integer()]) -> {[integer()], [integer()]}.
make_equal_length(T, NPTS) when length(NPTS) =/= length(T) ->
    case {T, NPTS} of
        {T1, []} ->
            {T1, [0 || _ <- T]};
        {T1, NPTS1} when length(T1) > length(NPTS1) ->
            N = length(T1) - length(NPTS1),
            {lists:nthtail(N, T1), NPTS1};
        {T1, NPTS1} when length(T1) < length(NPTS1) ->
            N = length(NPTS1) - length(T1),
            {T1, lists:nthtail(N, NPTS1)}
    end.

latency99(_Type, 0, Lats) ->
    Lats;
latency99(_Type, QE, Lats) ->
    case quantile_estimator:inserts_since_compression(QE) of
        0 ->
            Lats;
        _ ->
            [quantile_estimator:quantile(0.99, QE) | Lats]
    end.

-spec sum_tps(workload(), tps(), [integer()]) -> [integer()].
sum_tps(t1, #tps{t1 = T}, NTPS) ->
    {T2, NTPS2} =
        case length(T) =/= length(NTPS) of
            true ->
                make_equal_length(T, NTPS);
            false ->
                {T, NTPS}
        end,
    Adder2 = fun(X, Y) -> X + Y end,
    lists:zipwith(Adder2, T2, NTPS2);
sum_tps(t2, #tps{t2 = T}, NTPS) ->
    {T2, NTPS2} =
        case length(T) =/= length(NTPS) of
            true ->
                make_equal_length(T, NTPS);
            false ->
                {T, NTPS}
        end,
    Adder2 = fun(X, Y) -> X + Y end,
    lists:zipwith(Adder2, T2, NTPS2);
sum_tps(t3, #tps{t3 = T}, NTPS) ->
    {T2, NTPS2} =
        case length(T) =/= length(NTPS) of
            true ->
                make_equal_length(T, NTPS);
            false ->
                {T, NTPS}
        end,
    Adder2 = fun(X, Y) -> X + Y end,
    lists:zipwith(Adder2, T2, NTPS2);
sum_tps(t4, #tps{t4 = T}, NTPS) ->
    {T2, NTPS2} =
        case length(T) =/= length(NTPS) of
            true ->
                make_equal_length(T, NTPS);
            false ->
                {T, NTPS}
        end,
    Adder2 = fun(X, Y) -> X + Y end,
    lists:zipwith(Adder2, T2, NTPS2);
sum_tps(t5, #tps{t5 = T}, NTPS) ->
    {T2, NTPS2} =
        case length(T) =/= length(NTPS) of
            true ->
                make_equal_length(T, NTPS);
            false ->
                {T, NTPS}
        end,
    Adder2 = fun(X, Y) -> X + Y end,
    lists:zipwith(Adder2, T2, NTPS2);
sum_tps(ping, #tps{ping = Ping}, NTPS) ->
    {Ping2, NTPS2} =
        case length(Ping) =/= length(NTPS) of
            true ->
                make_equal_length(Ping, NTPS);
            false ->
                {Ping, NTPS}
        end,
    Adder2 = fun(X, Y) -> X + Y end,
    lists:zipwith(Adder2, Ping2, NTPS2).

display_trans_stats(Prefix, [{_Tag, 0, 0, 0, 0, []} | Rest], NT, Micros, NG) ->
    display_trans_stats(Prefix, Rest, NT, Micros, NG);
display_trans_stats(Prefix, [{Tag, NC, NA, NB, NM, NCS} | Rest], NT, Micros, NG) ->
    Common =
        fun(Name) ->
           Sec = NM / (1000000 * NG),
           io:format("  ~s: ~p (~p%) Time: ~p sec TPS = ~p~n, transactions per second~p~n",
                     [Name,
                      NC + NA,
                      round((NC + NA) * 100 / NT),
                      round(Sec),
                      round((NC + NA) / Sec),
                      NCS])
        end,
    Branch =
        fun() ->
           io:format("      Branches Executed: ~p (~p%)~n", [NB, round(NB * 100 / (NC + NA))])
        end,
    Rollback =
        fun() ->
           io:format("      Rollback Executed: ~p (~p%)~n", [NA, round(NA * 100 / (NC + NA))])
        end,
    case Tag of
        t1 ->
            Common("T1");
        t2 ->
            Common("T2");
        t3 ->
            Common("T3"),
            Branch();
        t4 ->
            Common("T4"),
            Branch(),
            Rollback();
        t5 ->
            Common("T5"),
            Branch(),
            Rollback();
        _ ->
            Common(io_lib:format("~p", [Tag]))
    end,
    display_trans_stats(Prefix, Rest, NT, Micros, NG);
display_trans_stats(_, [], _, _, _) ->
    ok.
