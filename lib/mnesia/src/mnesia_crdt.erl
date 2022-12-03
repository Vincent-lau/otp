-module(mnesia_crdt).

-include("mnesia.hrl").

-compile(export_all).
-compile(nowarn_export_all).

% TODO add type info
-record(async_op, {oid, ts, data_rcd, op}).

-type async_op() :: #async_op{}.

-spec create_op_tab() -> ok.
create_op_tab() ->
    io:format("creating op table~n"),
    mnesia:create_table(async_op,
                        [{type, bag},
                         {local_content, true},
                         {ram_copies, [node()]},
                         {disc_copies, []},
                         {disc_only_copies, []},
                         {attributes, record_info(fields, async_op)}]).

% HACK assuming there is only one record to be written for each async op
% But we really need to do is a per copy timestamp
% This is not a big problem as we can always split one async op into multiple
-spec check_ts(#commit{}) -> {boolean(), [#commit{}]}.
check_ts(#commit{ts = {VT, _PT} = Ts, ram_copies = [Copy = {Oid, _Val, _Op}]}) ->
    Ops = ets:lookup(async_op, Oid),
    {GT, Res} =
        lists:foldl(fun(AOp = #async_op{ts = {OldVT, _OldPT}}, {IsGT, CCList}) ->
                      case mnesia_vclock:compare_vclock(VT, OldVT) of
                          gt -> {IsGT andalso true, CCList};
                          lt -> {false, CCList};
                          cc -> {false, [AOp | CCList]}
                      end
                   end,
                   {true, []},
                   Ops),
    case GT of
        true ->
            true; % causality
        false
            when Res =:= [] -> % no concurrnet, no need to resolve
            false;
        false -> % concurrent
            resolve(gen_op(Ts, Copy), Res)
    end.

-spec resolve(#async_op{}, [#async_op{}]) -> boolean().
resolve(#async_op{ts = {_, PT1}}, Ops) ->
    % TODO need to add more behaviour for OR set
    lists:all(fun(#async_op{ts = {_, PT2}}) -> PT1 > PT2 end, Ops).

-spec gen_op(mnesia_vclock:vector_clock(), any()) -> [async_op()].
gen_op(Ts, {Oid, Val, Op}) ->
    #async_op{oid = Oid,
              ts = Ts,
              data_rcd = Val,
              op = Op}.

-spec add_op(#commit{}) -> ok.
add_op(#commit{ts = Ts, ram_copies = RamCopies}) ->
    WriteOp =
        fun(Oid, Val, Op) ->
           % HACK directly adding to the ets table
           % either crate an ets table or use the mnesia built-in functions
           ?ets_insert(async_op, gen_op(Ts, {Oid, Val, Op}))
        end,
    lists:foreach(fun({Oid, Val, Op}) -> WriteOp(Oid, Val, Op) end, RamCopies).
