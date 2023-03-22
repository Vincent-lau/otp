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
%%% File    : bench_trans.hrl
%%% Author  : Hakan Mattsson <hakan@cslab.ericsson.se>
%%% Purpose : Implement the transactions in Canadian database benchmark (LMC/UU-01:025)
%%% Created : 21 Jun 2001 by Hakan Mattsson <hakan@cslab.ericsson.se>
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-module(bench_async).

-compile(debug_info).

-author('sl955@cam.ac.uk').

-include("bench.hrl").

-export([update_current_location/5, read_current_location/2, read_session_details/4,
         create_session_to_server/6, delete_session_from_server/5, number_to_suffix/1,
         number_to_key/2]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% The transactions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% -------------------------------------------------------------------
%% T1 - Update current location
%% read a subscriber record and update its location
%% -------------------------------------------------------------------

update_current_location(Wlock, SubscrId, Location, ChangedBy, ChangedTime) ->
    Subscr = busy_read(subscriber, SubscrId),
    Subscr2 =
        Subscr#subscriber{location = Location,
                          changed_by = ChangedBy,
                          changed_time = ChangedTime},
    mnesia:write(subscriber, Subscr2, Wlock),
    {do_commit, false, [ok]}.

%% -------------------------------------------------------------------
%% T2 - Read current location
%% Just read a subscriber record and return its information
%% -------------------------------------------------------------------

read_current_location(_Wlock, SubscrId) ->
    Subscr = busy_read(subscriber, SubscrId),

    Name = Subscr#subscriber.subscriber_name,
    Location = Subscr#subscriber.location,
    ChangedBy = Subscr#subscriber.changed_by,
    ChangedTime = Subscr#subscriber.changed_time,
    {do_commit, false, [Name, Location, ChangedBy, ChangedTime]}.

%% -------------------------------------------------------------------
%% T3 - Read session details
%% Read a subscriber record, and the group to which it belongs.
%% Read the session of the subscriber and the server
%% update the server table on number of reads
%% return the session details
%% -------------------------------------------------------------------

read_session_details(Wlock, SubscrId, ServerBit, ServerId) ->
    Suffix = number_to_suffix(SubscrId),
    Subscr = busy_read(subscriber, SubscrId),
    %%[Group]  = mnesia:read(group, Subscr#subscriber.group_id, read),
    Group = busy_read(group, Subscr#subscriber.group_id),

    IsAllowed = Group#group.allow_read band ServerBit == ServerBit,
    IsActive = Subscr#subscriber.active_sessions band ServerBit == ServerBit,
    ExecuteBranch = IsAllowed and IsActive,

    case ExecuteBranch of
        true ->
            SessionKey = {SubscrId, ServerId},
            Session = busy_read(session, SessionKey),

            ServerKey = {ServerId, Suffix},
            Server = busy_read(server, ServerKey),
            Server2 = Server#server{no_of_read = Server#server.no_of_read + 1},
            mnesia:write(server, Server2, Wlock),
            {do_commit, ExecuteBranch, [Session#session.session_details]};
        false ->
            {do_commit, ExecuteBranch, []}
    end.

%% -------------------------------------------------------------------
%% T4 - Create session to server
%% Read a subscriber record, and the group to which it belongs.
%% create a new session for the subscriber and server and write into subscriber,
%% and subscriber table
%% update the server table on number of inserts
%% 
%% -------------------------------------------------------------------

create_session_to_server(Wlock, SubscrId, ServerBit, ServerId, Details, DoRollback) ->
    Suffix = number_to_suffix(SubscrId),
    Subscr = busy_read(subscriber, SubscrId),
    %%[Group]  = mnesia:read(group, Subscr#subscriber.group_id, read),
    Group = busy_read(group, Subscr#subscriber.group_id),

    IsAllowed = Group#group.allow_insert band ServerBit == ServerBit,
    IsInactive = Subscr#subscriber.active_sessions band ServerBit == 0,
    ExecuteBranch = IsAllowed and IsInactive,
    case ExecuteBranch of
        true ->
            SessionKey = {SubscrId, ServerId},
            Session =
                #session{session_key = SessionKey,
                         session_details = Details,
                         suffix = Suffix},
            mnesia:write(session, Session, Wlock),
            Active = Subscr#subscriber.active_sessions bor ServerBit,
            Subscr2 = Subscr#subscriber{active_sessions = Active},
            mnesia:write(subscriber, Subscr2, Wlock),

            ServerKey = {ServerId, Suffix},
            Server = busy_read(server, ServerKey),
            Server2 = Server#server{no_of_insert = Server#server.no_of_insert + 1},
            mnesia:write(server, Server2, Wlock);
        false ->
            ignore
    end,
    case DoRollback of
        true ->
            mnesia:abort({do_rollback, ExecuteBranch, []});
        false ->
            {do_commit, ExecuteBranch, []}
    end.

%% -------------------------------------------------------------------
%% T5 - Delete session from server
%% Inverse of T4, delete the session and update the server table
%% -------------------------------------------------------------------

delete_session_from_server(Wlock, SubscrId, ServerBit, ServerId, DoRollback) ->
    Suffix = number_to_suffix(SubscrId),
    Subscr = busy_read(subscriber, SubscrId),
    %%[Group]  = mnesia:read(group, Subscr#subscriber.group_id, read),
    Group = busy_read(group, Subscr#subscriber.group_id),

    IsAllowed = Group#group.allow_delete band ServerBit == ServerBit,
    IsActive = Subscr#subscriber.active_sessions band ServerBit == ServerBit,
    ExecuteBranch = IsAllowed and IsActive,
    case ExecuteBranch of
        true ->
            SessionKey = {SubscrId, ServerId},
            mnesia:delete(session, SessionKey, Wlock),
            Active = Subscr#subscriber.active_sessions bxor ServerBit,
            Subscr2 = Subscr#subscriber{active_sessions = Active},
            mnesia:write(subscriber, Subscr2, Wlock),

            ServerKey = {ServerId, Suffix},
            Server = busy_read(server, ServerKey),
            Server2 = Server#server{no_of_delete = Server#server.no_of_delete + 1},
            mnesia:write(server, Server2, Wlock);
        false ->
            ignore
    end,
    case DoRollback of
        true ->
            mnesia:abort({do_rollback, ExecuteBranch, []});
        false ->
            {do_commit, ExecuteBranch, []}
    end.

number_to_suffix(SubscrId) when is_integer(SubscrId) ->
    SubscrId rem 100;
number_to_suffix(<<_:8/binary, TimesTen:8/integer, TimesOne:8/integer>>) ->
    (TimesTen - $0) * 10 + (TimesOne - $0).

number_to_key(Id, C) when is_integer(Id) ->
    case C#config.use_binary_subscriber_key of
        true ->
            list_to_binary(string:right(integer_to_list(Id), 10, $0));
        false ->
            Id
    end.

busy_read(Table, SubscrId) ->
    case mnesia:read(Table, SubscrId, read) of
        [] ->
            ?d("busy_read: retrying read of ~p:~p~n", [Table, SubscrId]),
            busy_read(Table, SubscrId);
        [Subscr] ->
            Subscr;
        Other when length(Other) > 1 ->
            hd(Other)
    end.
