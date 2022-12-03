-module(mnesia_vclock).

-export([start/0, get_ts/0, local_event/0, send_event/0, rcv_event/1, compare/2,
    compare_vclock/2]).
-export([init/1, handle_call/3, handle_cast/2]).

-behaviour(gen_server).

-type ord() :: lt | eq | gt | cc.
-type vclock() :: counters:counters_ref().

% outside view of the vclock
-type vector_clock() :: {[integer()], integer()}.


-record(state, {clk :: vclock()}).

start() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], []).

get_ts() ->
    gen_server:call(?MODULE, get_ts).

local_event() ->
    gen_server:call(?MODULE, local_event).

% these are handled by the same method
send_event() ->
    gen_server:call(?MODULE, {local_event}).

-spec rcv_event(vclock()) -> vector_clock().
rcv_event(Ts) ->
    gen_server:call(?MODULE, {rcv_evn, Ts}).

init(_Args) ->
    C = new(num_nodes()),
    {ok, #state{clk = C}}.

handle_call(get_ts, _From, #state{clk = C} = State) ->
    {reply, {vclock_list(C), erlang:system_time()}, State};
handle_call(local_event, _From, State = #state{clk = C}) ->
    ok = incr(C, my_index()),
    {reply, {vclock_list(C), erlang:system_time()}, State};
handle_call({rcv_evn, Lm}, _From, State = #state{clk = C}) ->
    lists:foreach(fun(Ix) ->
                     Larger = max(counters:get(Lm, Ix), counters:get(C, Ix)),
                     ok = counters:put(C, Ix, Larger)
                  end,
                  lists:seq(1, num_nodes())),
    ok = incr(C, my_index()),
    {reply, {vclock_list(C), erlang:system_time()}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

-spec new(integer()) -> vclock().
new(Size) ->
    counters:new(Size, []).

-spec incr(vclock(), integer()) -> ok.
incr(VClock, Index) ->
    counters:add(VClock, Index, 1).

-spec compare_vclock([integer()], [integer()]) -> ord().
compare_vclock(VClock1, VClock2) ->
    % HACK assume vclocks have the same length for now
    {Ls, Gs} =
        lists:foldl(fun({C1, C2}, {L, G}) ->
                      if C1 < C2 -> {L + 1, G};
                         C1 > C2 -> {L, G + 1}
                      end
                   end,
                   {0, 0},
                   lists:zip(VClock1, VClock2)),
    if Ls == 0 andalso Gs == 0 ->
           eq;
       Ls == 0 ->
           gt;
       Gs == 0 ->
           lt;
       true ->
           cc
    end.

-spec compare(vector_clock(), vector_clock()) -> boolean().
compare({VC1, PT1}, {VC2, PT2}) ->
    case compare_vclock(VC1, VC2) of
        gt -> true;
        _ -> PT1 > PT2
    end.

num_nodes() ->
    length(nodes()) + 1.

% HACK just assume names starting from a
-spec my_index() -> integer().
my_index() ->
    (hd(atom_to_list(node())) rem 97) + 1.

-spec vclock_list(counters:counters_ref()) -> [integer()].
vclock_list(Ref) ->
    lists:map(fun(Ix) -> counters:get(Ref, Ix) end, lists:seq(1, num_nodes())).
