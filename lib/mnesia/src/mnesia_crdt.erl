-module(mnesia_crdt).

-include("mnesia.hrl").

-compile(export_all).
-compile(nowarn_export_all).

% TODO add type info
-record(async_op, {oid, ts, data_rcd, op}).

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
check_ts(#commit{ts = Ts, ram_copies = [{Oid, _Val, _Op}]}) ->
    Commits = ets:lookup(async_op, Oid),
    TimeStamps = [OldTs || #async_op{ts = OldTs} <- Commits],
    case length(TimeStamps) of
        0 ->
            true;
        _N ->
            MaxTs = lists:max(TimeStamps),
            Ts > MaxTs
    end.

add_op(#commit{ts = Ts, ram_copies = RamCopies}) ->
    WriteOp =
        fun(Oid, Val, Op) ->
           % HACK directly adding to the ets table
           % either crate an ets table or use the mnesia built-in functions
           ?ets_insert(async_op,
                       #async_op{oid = Oid,
                                 ts = Ts,
                                 data_rcd = Val,
                                 op = Op})
        end,
    lists:foreach(fun({Oid, Val, Op}) -> WriteOp(Oid, Val, Op) end, RamCopies).
