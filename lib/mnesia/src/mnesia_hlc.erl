-module(mnesia_hlc).

-export([local_event/0, send_event/0, rcv_event/1, get_ts/0]).
-export([start/0, init/1, handle_call/3, handle_cast/2]).

-type hlc() :: {integer(), integer()}.

-record(state,
        {l :: non_neg_integer(),  % previous logical time
         c :: non_neg_integer()}).

-behaviour(gen_server).

start() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_ts() ->
    gen_server:call(?MODULE, get_ts).

local_event() ->
    gen_server:call(?MODULE, local_event).

% these are handled by the same method
send_event() ->
    gen_server:call(?MODULE, {local_event}).

-spec rcv_event(hlc()) -> hlc().
rcv_event(Ts) ->
    gen_server:call(?MODULE, {rcv_evn, Ts}).

init(_Args) ->
    {ok, #state{l = 0, c = 0}}.

handle_call(get_ts, _From, #state{l = L, c = C} = State) ->
    {reply, {L, C}, State};
handle_call(local_event, _From, #state{l = L1, c = C1}) ->
    L2 = max(L1, erlang:system_time()),
    C2 = case L2 == L1 of
             true ->
                 C1 + 1;
             false ->
                 0
         end,
    {reply, {L2, C2}, #state{l = L2, c = C2}};
handle_call({rcv_evn, {Lm, Cm}}, _From, #state{l = L1, c = C1}) ->
    L2 = max(Lm, max(L1, erlang:system_time())),
    C2 = if L2 == L1 andalso L2 == Lm ->
                max(Cm, C1) + 1;
            L2 == L1 ->
                C1 + 1;
            L2 == Lm ->
                Cm + 1;
            true ->
                0
         end,
    {reply, {L2, C2}, #state{l = L2, c = C2}}.

handle_cast(_Msg, State) ->
    {noreply, State}.
