-module(mnesia_vclock).

-include("mnesia.hrl").

-compile(export_all).
-compile(nowarn_export_all).

-type ord() :: lt | eq | gt | cc.
-type vclock() :: counters:counters_ref().

-spec new(integer()) -> vclock().
new(Size) ->
    counters:new(Size).

-spec incr(vclock(), integer()) -> ok.
incr(VClock, Index) ->
    counters:add(VClock, Index, 1).

-spec compare(vclock(), vclock()) -> ord().
compare(VClock1, VClock2) ->
    S1 = maps:get(size, counters:info(VClock1)),
    S2 = maps:get(size, counters:info(VClock2)),
    S = max(S1, S2),
    % HACK assume vclocks have the same length for now
    {Ls, Gs} =
        lists:fold(fun(I, {L, G}) ->
                      C1 = counters:get(VClock1, I),
                      C2 = counters:get(VClock2, I),
                      if C1 < C2 -> {L + 1, G};
                         C1 > C2 -> {L, G + 1}
                      end
                   end,
                   lists:seq(1, S),
                   {0, 0}),
    if Ls == 0 andalso Gs == 0 ->
           eq;
       Ls == 0 ->
           gt;
       Gs == 0 ->
           lt;
       true ->
           cc
    end.
