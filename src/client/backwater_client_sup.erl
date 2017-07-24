-module(backwater_client_sup).
-behaviour(supervisor).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/2]).
-export([child_spec/3]).

%% ------------------------------------------------------------------
%% supervisor Function Exports
%% ------------------------------------------------------------------

-export([init/1]).

%% ------------------------------------------------------------------
%% Macro Definitions
%% ------------------------------------------------------------------

-define(CB_MODULE, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Ref, ClientConfig) ->
    supervisor:start_link({local, server_name(Ref)}, ?CB_MODULE, [Ref, ClientConfig]).

child_spec(Id, Ref, ClientConfig) ->
    #{ id => Id,
       start => {?MODULE, start_link, [Ref, ClientConfig]},
       restart => transient,
       type => supervisor,
       modules => [?MODULE] }.

%% ------------------------------------------------------------------
%% supervisor Function Definitions
%% ------------------------------------------------------------------

init([Ref, ClientConfig]) ->
    Children = [backwater_client_config:child_spec(config, Ref, ClientConfig)],
    {ok, {#{}, Children}}.

%% ------------------------------------------------------------------
%% supervisor Function Definitions
%% ------------------------------------------------------------------

server_name(Ref) ->
    list_to_atom("backwater_" ++ backwater_ref:to_unicode_string(Ref) ++ "_client_sup").
