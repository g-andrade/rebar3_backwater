%% Copyright (c) 2017 Guilherme Andrade <backwater@gandrade.net>
%%
%% Permission is hereby granted, free of charge, to any person obtaining a
%% copy  of this software and associated documentation files (the "Software"),
%% to deal in the Software without restriction, including without limitation
%% the rights to use, copy, modify, merge, publish, distribute, sublicense,
%% and/or sell copies of the Software, and to permit persons to whom the
%% Software is furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
%% DEALINGS IN THE SOFTWARE.

-module(backwater_cowboy2_handler).
-behaviour(cowboy_handler).

-include("backwater_common.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([initial_state/1]).

%% ------------------------------------------------------------------
%% cowboy_handler Function Exports
%% ------------------------------------------------------------------

-export([init/2]).
-export([terminate/3]).

%% ------------------------------------------------------------------
%% Macro Definitions
%% ------------------------------------------------------------------

-define(CACHED_FUNCTION_PROPERTIES_TTL, (timer:seconds(5))).
-define(KNOWN_CONTENT_ENCODINGS, [<<"gzip">>, <<"identity">>]).

-define(DEFAULT_OPT_COMPRESSION_THRESHOLD, 300). % in bytes
-define(DEFAULT_OPT_DECODE_UNSAFE_TERMS, false).
-define(DEFAULT_OPT_MAX_ENCODED_ARGS_SIZE, (8 * (1 bsl 20))). % in bytes
-define(DEFAULT_OPT_RECV_TIMEOUT, 5000). % in milliseconds
-define(DEFAULT_OPT_RETURN_EXCEPTION_STACKTRACES, true).

%% ------------------------------------------------------------------
%% Type Definitions
%% ------------------------------------------------------------------

-opaque state() ::
        #{ config := config(),

           req => req(),
           bin_module => binary(),
           bin_function => binary(),
           arity => arity(),

           signed_request_msg => backwater_http_signatures:signed_message(),

           function_properties => backwater_module_info:fun_properties(),
           args_content_type => content_type(),
           args_content_encoding => binary(),
           args => [term()],
           response => response(),
           accepted_result_content_types => [accepted_content_type()],
           accepted_result_content_encodings => [accepted_content_encoding()],
           result_content_type => content_type(),
           result_content_encoding => binary() }.
-export_type([state/0]).

-type config() ::
        #{ secret := binary(),
           exposed_modules := [backwater_module_info:exposed_module()],

           compression_threshold => non_neg_integer(),
           decode_unsafe_terms => boolean(),
           max_encoded_args_size => non_neg_integer(),
           recv_timeout => timeout(),
           return_exception_stacktraces => boolean() }.
-export_type([config/0]).

-type accepted_content_type() :: {content_type(), Quality :: 0..1000, accepted_ext()}.

-type accepted_ext() :: [{binary(), binary()} | binary()].

-type accepted_content_encoding() :: {content_type(), Quality :: 0..1000}.

-type call_result() :: {return, term()} | call_exception().

-type call_exception() :: {exception, {raisable_class(), Exception :: term(), [erlang:stack_item()]}}.

-type content_type() :: {Type :: binary(), SubType :: binary(), content_type_params()}.

-type content_type_params() :: [{binary(), binary()}].

-type http_headers() :: backwater_cowboy2_req:http_headers().

-type http_status() :: backwater_cowboy2_req:http_status().

-type req() :: backwater_cowboy2_req:t().

-type raisable_class() :: error | exit | throw.

-type response() ::
        #{ status_code := http_status(),
           headers := http_headers(),
           body := iodata() }.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

-spec initial_state(config()) -> {ok, state()} | {error, backwater_util:config_validation_error()}.
%% @private
initial_state(Config) ->
    ValidationResult = backwater_util:validate_config_map(Config, [secret, exposed_modules],
                                                          fun validate_config_pair/1),
    case ValidationResult of
        {ok, ValidatedConfig} ->
            {ok, #{ config => ValidatedConfig }};
        {error, Error} ->
            {error, Error}
    end.

%% ------------------------------------------------------------------
%% cowboy_handler Function Definitions
%% ------------------------------------------------------------------

-spec init(req(), state()) -> {ok, req(), state()}.
%% @private
init(Req1, State1) ->
    State2 = State1#{ req => Req1 },
    State3 =
        execute_pipeline(
          [fun check_authentication/1,
           fun check_method/1,
           fun parse_path/1,
           fun check_authorization/1,
           fun check_existence/1,
           fun check_args_content_type/1,
           fun check_args_content_encoding/1,
           fun check_accepted_result_content_types/1,
           fun check_accepted_result_content_encodings/1,
           fun negotiate_args_content_type/1,
           fun negotiate_args_content_encoding/1,
           fun negotiate_result_content_type/1,
           fun negotiate_result_content_encoding/1,
           fun read_and_decode_args/1,
           fun execute_call/1],
          State2),

    {Req2, State4} = maps:take(req, State3),
    {ok, Req2, State4}.

-spec terminate(term(), req(), state()) -> ok.
%% @private
%terminate({crash, Class, Reason}, _Req, _State) ->
%    Stacktrace = erlang:get_stacktrace(),
%    io:format("Crash! ~p:~p, ~p~n", [Class, Reason, Stacktrace]),
%    ok;
terminate(_Reason, _Req, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions - Pipeline
%% ------------------------------------------------------------------

-spec execute_pipeline([fun ((state()) -> {continue | stop, state()}), ...], state())
        -> state().
execute_pipeline([Handler | NextHandlers], State1) ->
    case Handler(State1) of
        {continue, State2} ->
            execute_pipeline(NextHandlers, State2);
        {stop, State2} ->
            send_response(State2)
    end;
execute_pipeline([], State) ->
    send_response(State).

%% ------------------------------------------------------------------
%% Internal Function Definitions - Check Authentication
%% ------------------------------------------------------------------

-spec check_authentication(state()) -> {continue | stop, state()}.
check_authentication(#{ req := Req, config := #{ secret := Secret } } = State) ->
    SignaturesConfig = backwater_http_signatures:config(Secret),
    Method = backwater_cowboy2_req:method(Req),
    EncodedPathWithQs = req_encoded_path_with_qs(Req),
    Headers = backwater_cowboy2_req:headers(Req),
    RequestMsg =
        backwater_http_signatures:new_request_msg(Method, EncodedPathWithQs, {ci_headers, Headers}),

    case backwater_http_signatures:validate_request_signature(SignaturesConfig, RequestMsg) of
        {ok, SignedRequestMsg} ->
            {continue, State#{ signed_request_msg => SignedRequestMsg }};
        {error, Reason} ->
            AuthChallengeHeaders =
                backwater_http_signatures:get_request_auth_challenge_headers(RequestMsg),
            {stop, set_error_response(401, AuthChallengeHeaders, Reason, State)}
    end.

-spec req_encoded_path_with_qs(req()) -> binary().
req_encoded_path_with_qs(Req) ->
    EncodedPath = backwater_cowboy2_req:path(Req),
    QueryString = backwater_cowboy2_req:qs(Req),
    <<EncodedPath/binary, QueryString/binary>>.

-spec safe_req_header(binary(), state()) -> undefined | binary() | no_return().
safe_req_header(CiName, #{ req := Req } = State) ->
    case backwater_cowboy2_req:header(CiName, Req) of
        undefined -> undefined;
        Value ->
            assert_header_safety(CiName, State),
            Value
    end.

-spec safe_req_parse_header(binary(), state()) -> term() | no_return().
safe_req_parse_header(CiName, State) ->
    safe_req_parse_header(CiName, State, undefined, undefined).

-spec safe_req_parse_header(binary(), state(), term(), term()) -> term() | no_return().
safe_req_parse_header(CiName, #{ req := Req } = State, Undefined, Default) ->
    case backwater_cowboy2_req:parse_header(CiName, Req) of
        Undefined -> Default;
        Value ->
            assert_header_safety(CiName, State),
            Value
    end.

-spec assert_header_safety(binary(), state()) -> true | no_return().
assert_header_safety(CiName, #{ signed_request_msg := SignedRequestMsg }) ->
    backwater_http_signatures:is_header_signed_in_signed_msg(CiName, SignedRequestMsg)
    orelse error({using_unsafe_header, CiName}).

%% ------------------------------------------------------------------
%% Internal Function Definitions - Check Method
%% ------------------------------------------------------------------

-spec check_method(state()) -> {continue | stop, state()}.
check_method(#{ req := Req } = State) ->
    case backwater_cowboy2_req:method(Req) =:= <<"POST">> of
        true ->
            {continue, State};
        false ->
            {stop, set_error_response(405, State)}
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions - Parse Path
%% ------------------------------------------------------------------

-spec parse_path(state()) -> {continue | stop, state()}.
parse_path(#{ req := Req } = State) ->
    case backwater_cowboy2_req:path_info(Req) of
        [BinModule, BinFunction, BinArity] ->
            parse_path(BinModule, BinFunction, BinArity, State);
        Other when is_list(Other) ->
            {stop, set_error_response(400, #{}, invalid_path, State)}
    end.

-spec parse_path(binary(), binary(), binary(), state())
        -> {continue | stop, state()}.
parse_path(BinModule, BinFunction, BinArity, State1) ->
    case arity_from_binary(BinArity) of
        {ok, Arity} ->
            State2 =
                State1#{ bin_module => BinModule,
                         bin_function => BinFunction,
                         arity => Arity },
            {continue, State2};
        error ->
            {stop, set_error_response(400, #{}, invalid_arity, State1)}
    end.

-spec arity_from_binary(binary()) -> {ok, arity()} | error.
arity_from_binary(BinArity) ->
    try binary_to_integer(BinArity) of
        Integer when Integer > 255 -> error;
        Integer when Integer < 0 -> error;
        Arity -> {ok, Arity}
    catch
        error:badarg -> error
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions - Check Request Authorization
%% ------------------------------------------------------------------

-spec check_authorization(state()) -> {continue | stop, state()}.
check_authorization(State) ->
    #{ bin_module := BinModule,
       config := #{ exposed_modules := ExposedModules } } = State,

    SearchResult =
        lists:any(
          fun (ExposedModule) ->
                  ModuleName = backwater_module_info:exposed_module_name(ExposedModule),
                  BinModule =:= atom_to_binary(ModuleName, utf8)
          end,
          ExposedModules),

    case SearchResult of
        true -> {continue, State};
        false -> {stop, set_error_response(403, State)}
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions - Check Resource Existence
%% ------------------------------------------------------------------

-spec check_existence(state()) -> {continue | stop, state()}.
check_existence(State) ->
    case find_function_properties(State) of
        {found, FunctionProperties} ->
            {continue, State#{ function_properties => FunctionProperties }};
        Error ->
            {stop, set_error_response(404, #{}, Error, State)}
    end.

-spec find_function_properties(state())
        -> {found, backwater_module_info:fun_properties()} | Error
             when Error :: (function_not_found |
                            module_not_found).
find_function_properties(State) ->
    CacheKey = function_properties_cache_key(State),
    CachedFunctionPropertiesLookup = backwater_cache:find(CacheKey),
    handle_cached_function_properties_lookup(CachedFunctionPropertiesLookup, State).

-spec handle_cached_function_properties_lookup({ok, backwater_module_info:fun_properties()} | error, state())
        -> {found, backwater_module_info:fun_properties()} |
           module_not_found |
           function_not_found.
handle_cached_function_properties_lookup({ok, FunctionProperties}, _State) ->
    {found, FunctionProperties};
handle_cached_function_properties_lookup(error, State) ->
    #{ bin_module := BinModule,
       config := #{ exposed_modules := ExposedModules  } } = State,
    InfoPerExposedModule = backwater_module_info:generate(ExposedModules),
    InfoLookup = maps:find(BinModule, InfoPerExposedModule),
    handle_module_info_lookup(InfoLookup, State).

-spec handle_module_info_lookup({ok, backwater_module_info:module_info()}, state())
        -> {found, backwater_module_info:fun_properties()} |
           module_not_found |
           function_not_found.
handle_module_info_lookup({ok, Info}, State) ->
    #{ exports := Exports } = Info,
    #{ bin_function := BinFunction, arity := Arity } = State,
    FunctionPropertiesLookup = maps:find({BinFunction, Arity}, Exports),
    handle_function_properties_lookup(FunctionPropertiesLookup, State);
handle_module_info_lookup(error, _State) ->
    module_not_found.

-spec handle_function_properties_lookup({ok, backwater_module_info:fun_properties()} | error, state())
        -> {found, backwater_module_info:fun_properties()} |
           function_not_found.
handle_function_properties_lookup({ok, FunctionProperties}, State) ->
    % let's only fill successful lookups so that we don't risk
    % overloading the cache if attacked (the trade off is potentially
    % much higher CPU usage)
    CacheKey = function_properties_cache_key(State),
    backwater_cache:put(CacheKey, FunctionProperties, ?CACHED_FUNCTION_PROPERTIES_TTL),
    {found, FunctionProperties};
handle_function_properties_lookup(error, _State) ->
    function_not_found.

-spec function_properties_cache_key(state())
        -> {exposed_function_properties, binary(), binary(), arity()}.
function_properties_cache_key(State) ->
    #{ bin_module := BinModule,
       bin_function := BinFunction,
       arity := Arity } = State,
    {exposed_function_properties, BinModule, BinFunction, Arity}.

%% ------------------------------------------------------------------
%% Internal Function Definitions - Validate Arguments Content Type
%% ------------------------------------------------------------------

-spec check_args_content_type(state()) -> {continue | stop, state()}.
check_args_content_type(State) ->
    case safe_req_parse_header(<<"content-type">>, State) of
        {_, _, _} = ContentType ->
            State2 = State#{ args_content_type => ContentType },
            {continue, State2};
        undefined ->
            {stop, set_error_response(400, #{}, bad_content_type, State)}
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions - Validate Arguments Content Encoding
%% ------------------------------------------------------------------

-spec check_args_content_encoding(state()) -> {continue, state()}.
check_args_content_encoding(State) ->
    case safe_req_header(<<"content-encoding">>, State) of
        <<ContentEncoding/binary>> ->
            State2 = State#{ args_content_encoding => ContentEncoding },
            {continue, State2};
        undefined ->
            State2 = State#{ args_content_encoding => <<"identity">> },
            {continue, State2}
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions - Validate Accepted Content Types
%% ------------------------------------------------------------------

-spec check_accepted_result_content_types(state()) -> {continue, state()}.
check_accepted_result_content_types(State) ->
    AcceptedContentTypes = safe_req_parse_header(<<"accept">>, State, undefined, []),
    SortedAcceptedContentTypes = lists:reverse( lists:keysort(2, AcceptedContentTypes) ),
    State2 = State#{ accepted_result_content_types => SortedAcceptedContentTypes },
    {continue, State2}.

%% ------------------------------------------------------------------
%% Internal Function Definitions - Validate Accepted Content Encodings
%% ------------------------------------------------------------------

-spec check_accepted_result_content_encodings(state()) -> {continue, state()}.
check_accepted_result_content_encodings(State) ->
    AcceptedContentEncodings = safe_req_parse_header(<<"accept-encoding">>, State, undefined, []),
    SortedAcceptedContentEncodings = lists:reverse( lists:keysort(2, AcceptedContentEncodings) ),
    State2 = State#{ accepted_result_content_encodings => SortedAcceptedContentEncodings },
    {continue, State2}.

%% ------------------------------------------------------------------
%% Internal Function Definitions - Negotiate Arguments Content Type
%% ------------------------------------------------------------------

-spec negotiate_args_content_type(state()) -> {continue | stop, state()}.
negotiate_args_content_type(State) ->
    #{ function_properties := FunctionProperties,
       args_content_type := ArgsContentType } = State,
    #{ known_content_types := KnownContentTypes } = FunctionProperties,

    {Type, SubType, _ContentTypeParams} = ArgsContentType,
    SearchResult = lists:member({Type, SubType}, KnownContentTypes),

    case SearchResult of
        true ->
            {continue, State};
        false ->
            {stop, set_error_response(415, #{}, unsupported_content_type, State)}
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions - Negotiate Arguments Content Encoding
%% ------------------------------------------------------------------

-spec negotiate_args_content_encoding(state()) -> {continue | stop, state()}.
negotiate_args_content_encoding(State) ->
    #{ args_content_encoding := ArgsContentEncoding } = State,
    case lists:member(ArgsContentEncoding, ?KNOWN_CONTENT_ENCODINGS) of
        true ->
            {continue, State};
        false ->
            {stop, set_error_response(415, #{}, unsupported_content_encoding, State)}
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions - Negotiate Result Content Type
%% ------------------------------------------------------------------

-spec negotiate_result_content_type(state()) -> {continue | stop, state()}.
negotiate_result_content_type(State) ->
    #{ function_properties := FunctionProperties,
       accepted_result_content_types := AcceptedContentTypes } = State,
    #{ known_content_types := KnownContentTypes } = FunctionProperties,

    SearchResult =
        backwater_util:lists_anymap(
          fun ({{Type, SubType, _Params} = ContentType, _Quality, _AcceptExt}) ->
                  (lists:member({Type, SubType}, KnownContentTypes)
                   andalso {true, ContentType})
          end,
          AcceptedContentTypes),

    case SearchResult of
        {true, ContentType} ->
            State2 = State#{ result_content_type => ContentType },
            {continue, State2};
        false ->
            {stop, set_error_response(406, State)}
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions - Negotiate Result Content Encoding
%% ------------------------------------------------------------------

-spec negotiate_result_content_encoding(state()) -> {continue | stop, state()}.
negotiate_result_content_encoding(State) ->
    #{ accepted_result_content_encodings := AcceptedContentEncodings } = State,

    SearchResult =
        backwater_util:lists_anymap(
          fun ({Encoding, _Params}) ->
                  (lists:member(Encoding, ?KNOWN_CONTENT_ENCODINGS)
                   andalso {true, Encoding})
          end,
          AcceptedContentEncodings),

    case SearchResult of
        {true, ContentEncoding} ->
            State2 = State#{ result_content_encoding => ContentEncoding },
            {continue, State2};
        false ->
            State2 = State#{ result_content_encoding => <<"identity">> },
            {continue, State2}
    end.

%% ------------------------------------------------------------------
%% Internal Function Definitions - Read and Decode Arguments
%% ------------------------------------------------------------------

-spec read_and_decode_args(state()) -> {continue | stop, state()}.
read_and_decode_args(State) ->
    BodySize = safe_req_parse_header(<<"content-length">>, State, 0, 0),
    MaxEncodedArgsSize = opt_max_encoded_args_size(State),
    read_and_decode_args(BodySize, MaxEncodedArgsSize, State).

-spec read_and_decode_args(non_neg_integer(), non_neg_integer(), state())
        -> {continue | stop, state()}.
read_and_decode_args(BodySize, MaxEncodedArgsSize, State) when BodySize > MaxEncodedArgsSize ->
    {stop, set_error_response(413, State)};
read_and_decode_args(BodySize, _MaxEncodedArgsSize, State) ->
    #{ req := Req } = State,
    RecvTimeout = opt_recv_timeout(State),
    ReadBodyOpts =
        #{ length => BodySize,
           period => RecvTimeout },

    case backwater_cowboy2_req:read_body(Req, ReadBodyOpts) of
        {ok, Data, Req2} when byte_size(Data) =< BodySize ->
            State2 = State#{ req := Req2 },
            validate_args_digest(Data, State2);
        {Status, _Data, Req2} when Status =:= more; Status =:= ok ->
            State2 = State#{ req := Req2 },
            {stop, set_error_response(413, State2)}
    end.

-spec validate_args_digest(binary(), state()) -> {continue | stop, state()}.
validate_args_digest(Data, State) ->
    #{ signed_request_msg := SignedRequestMsg } = State,
    case backwater_http_signatures:validate_signed_msg_body(SignedRequestMsg, Data) of
        true ->
            decode_args_content_encoding(Data, State);
        false ->
            AuthChallengeHeaders =
                backwater_http_signatures:get_request_auth_challenge_headers(SignedRequestMsg),
            {stop, set_error_response(401, AuthChallengeHeaders, wrong_arguments_digest, State)}
    end.

-spec decode_args_content_encoding(binary(), state()) -> {continue | stop, state()}.
decode_args_content_encoding(Data, #{ args_content_encoding := <<"identity">> } = State) ->
    decode_args_content_type(Data, State);
decode_args_content_encoding(Data, #{ args_content_encoding := <<"gzip">> } = State) ->
    MaxEncodedArgsSize = opt_max_encoded_args_size(State),
    case backwater_encoding_gzip:decode(Data, MaxEncodedArgsSize) of
        {ok, UncompressedData} ->
            decode_args_content_type(UncompressedData, State);
        {error, too_big} ->
            {stop, set_error_response(413, State)};
        {error, _} ->
            {stop, set_error_response(400, #{}, unable_to_uncompress_arguments, State)}
    end.

-spec decode_args_content_type(binary(), state()) -> {continue | stop, state()}.
decode_args_content_type(Data, State) ->
    #{ args_content_type := ArgsContentType } = State,
    case ArgsContentType of
        {<<"application">>, <<"x-erlang-etf">>, _Params} ->
            decode_etf_args(Data, State)
    end.

-spec decode_etf_args(binary(), state()) -> {continue | stop, state()}.
decode_etf_args(Data, State) ->
    DecodeUnsafeTerms = opt_decode_unsafe_terms(State),
    case backwater_media_etf:decode(Data, DecodeUnsafeTerms) of
        error ->
            {stop, set_error_response(400, #{}, unable_to_decode_arguments, State)};
        {ok, UnvalidatedArgs} ->
            validate_args(UnvalidatedArgs, State)
    end.

-spec validate_args(term(), state()) -> {continue | stop, state()}.
validate_args(UnvalidatedArgs, State)
  when not is_list(UnvalidatedArgs) ->
    {stop, set_error_response(400, #{}, arguments_not_a_list, State)};
validate_args(UnvalidatedArgs, #{ arity := Arity } = State)
  when length(UnvalidatedArgs) =/= Arity ->
    {stop, set_error_response(400, #{}, inconsistent_arguments_arity, State)};
validate_args(Args, State) ->
    {continue, State#{ args => Args }}.

-spec opt_decode_unsafe_terms(state()) -> boolean().
opt_decode_unsafe_terms(State) ->
    config_opt(decode_unsafe_terms, State, ?DEFAULT_OPT_DECODE_UNSAFE_TERMS).

-spec opt_max_encoded_args_size(state()) -> non_neg_integer().
opt_max_encoded_args_size(State) ->
    config_opt(max_encoded_args_size, State, ?DEFAULT_OPT_MAX_ENCODED_ARGS_SIZE).

-spec opt_recv_timeout(state()) -> timeout().
opt_recv_timeout(State) ->
    config_opt(recv_timeout, State, ?DEFAULT_OPT_RECV_TIMEOUT).

%% ------------------------------------------------------------------
%% Internal Function Definitions - Execute Call
%% ------------------------------------------------------------------

-spec execute_call(state()) -> {continue, state()}.
execute_call(State) ->
    case call_function(State) of
        {ok, Result} ->
            {continue, set_success_response(Result, State)};
        {error, undefined_module_or_function} ->
            % It's important to handle this situation gracefully, as the remote caller
            % really isn't to blame that we're bad at keeping track of module upgrades.
            {stop, set_error_response(404, #{}, module_or_function_not_found, State)}
    end.

-spec call_function(state()) -> {ok, call_result()} | {error, undefined_module_or_function}.
call_function(State) ->
    #{ function_properties := FunctionProperties, args := FunctionArgs } = State,
    #{ function_ref := FunctionRef } = FunctionProperties,
    try
        {ok, {return, apply(FunctionRef, FunctionArgs)}}
    catch
        Class:Exception ->
            handle_possibly_undef_call_exception(Class, Exception, State, FunctionRef)
    end.

-spec handle_possibly_undef_call_exception(raisable_class(), term(), state(), fun())
        -> {ok, call_exception()} | {error, undefined_module_or_function}.
handle_possibly_undef_call_exception(Class, Exception, State, FunctionRef)
  when Class =:= error, Exception =:= undef ->
    ReturnExceptionStacktraces = opt_return_exception_stack_traces(State),
    {module, Module} = erlang:fun_info(FunctionRef, module),
    {name, Name} = erlang:fun_info(FunctionRef, name),
    {arity, Arity} = erlang:fun_info(FunctionRef, arity),
    case erlang:get_stacktrace() of
        [{Module, Name, Args, _Location} | _] when is_list(Args), length(Args) =:= Arity ->
            % It looks like our target function or module has disappeared in the mean time,
            % either due to a stale cache or because the module has been (un/re)loaded.
            % Checking for this is expensive but limited to 'error:undef' exceptions,
            % so the average impact should be minimal, unless users are juggling around
            % a lot of calls to undefined functions or modules in their own code.
            % Don't bother clearing the cache as the TTL is low in any case.
            {error, undefined_module_or_function};
        Stacktrace when ReturnExceptionStacktraces ->
            return_call_exception(Class, Exception, Stacktrace);
        _Stacktrace when not ReturnExceptionStacktraces ->
            return_call_exception(Class, Exception, [])
    end;
handle_possibly_undef_call_exception(Class, Exception, State, _FunctionRef) ->
    handle_call_exception(Class, Exception, State).

-spec handle_call_exception(raisable_class(), term(), state()) -> {ok, call_exception()}.
handle_call_exception(Class, Exception, State) ->
    case opt_return_exception_stack_traces(State) of
        false ->
            return_call_exception(Class, Exception, []);
        true ->
            Stacktrace = erlang:get_stacktrace(),
            return_call_exception(Class, Exception, Stacktrace)
    end.

-spec return_call_exception(raisable_class(), term(), [erlang:stack_item()]) -> {ok, call_exception()}.
return_call_exception(Class, Exception, Stacktrace) ->
    % Hide all calls previous to the one made to the target function (cowboy stuff, etc.)
    % This works under the assumption that *no sensible call* would ever go through 'call_function/1' again.
    PurgedStacktrace = backwater_util:purge_stacktrace_below({?MODULE,call_function,1}, Stacktrace),
    {ok, {exception, {Class, Exception, PurgedStacktrace}}}.

-spec opt_return_exception_stack_traces(state()) -> boolean().
opt_return_exception_stack_traces(State) ->
    config_opt(return_exception_stacktraces, State, ?DEFAULT_OPT_RETURN_EXCEPTION_STACKTRACES).

%% ------------------------------------------------------------------
%% Internal Function Definitions - Send Response
%% ------------------------------------------------------------------

-spec send_response(state()) -> state().
send_response(#{ signed_request_msg := SignedRequestMsg } = State1) ->
    % signed response
    #{ req := Req1, response := Response } = State1,
    #{ status_code := ResponseStatusCode, headers := ResponseHeaders1, body := ResponseBody } = Response,

    #{ config := #{ secret := Secret } } = State1,
    ResponseHeaders2 =
        ResponseHeaders1#{ <<"content-length">> => integer_to_binary( byte_size(ResponseBody) ) },
    SignaturesConfig = backwater_http_signatures:config(Secret),
    ResponseMsg =
        backwater_http_signatures:new_response_msg(ResponseStatusCode, {ci_headers, ResponseHeaders2}),
    SignedResponseMsg =
        backwater_http_signatures:sign_response(SignaturesConfig, ResponseMsg, ResponseBody, SignedRequestMsg),
    ResponseHeaders3 = backwater_http_signatures:get_real_msg_headers(SignedResponseMsg),

    Req2 = backwater_cowboy2_req:reply(ResponseStatusCode, ResponseHeaders3, ResponseBody, Req1),
    State1#{ req := Req2 };
send_response(State1) ->
    % unsigned response
    #{ req := Req1, response := Response } = State1,
    #{ status_code := ResponseStatusCode, headers := ResponseHeaders, body := ResponseBody } = Response,
    Req2 = backwater_cowboy2_req:reply(ResponseStatusCode, ResponseHeaders, ResponseBody, Req1),
    State1#{ req := Req2 }.

%% ------------------------------------------------------------------
%% Internal Function Definitions - Set Response
%% ------------------------------------------------------------------

-spec set_error_response(http_status(), state()) -> state().
set_error_response(StatusCode, State) ->
    set_error_response(StatusCode, #{}, <<>>, State).

-spec set_error_response(http_status(), http_headers(), term(), state()) -> state().
set_error_response(StatusCode, BaseHeaders, Message, State1) ->
    % force text/plain response
    State2 = maps:without([result_content_encoding, result_content_type], State1),
    Headers = maps:merge(BaseHeaders, #{ <<"content-type">> => <<"text/plain">> }),
    Body = encode_error_message_body(Message),
    Response = encode_response(StatusCode, Headers, Body, State2),
    maps:put(response, Response, State2).

%-spec encode_error_message_body(term()) -> binary().
encode_error_message_body(Message) ->
    IoData =
        case backwater_util:is_iodata(Message) of
            true -> Message;
            false -> io_lib:format("~p", [Message])
        end,
    iolist_to_binary(IoData).

-spec set_success_response(term(), state()) -> state().
set_success_response(Value, #{ result_content_type := ResultContentType } = State) ->
    StatusCode = 200,
    {Type, SubType, _Params} = ResultContentType,
    ContentTypeHeaders = #{ <<"content-type">> => [Type, "/", SubType] },
    Headers = maps:merge(nocache_headers(), ContentTypeHeaders),
    Body =
        case {Type, SubType} of
            {<<"application">>, <<"x-erlang-etf">>} ->
                backwater_media_etf:encode(Value)
        end,
    Response = encode_response(StatusCode, Headers, Body, State),
    maps:put(response, Response, State).

-spec encode_response(http_status(), http_headers(), binary(), state()) -> response().
encode_response(StatusCode, Headers, Body, #{ result_content_encoding := <<"gzip">> } = State) ->
    CompressionThreshold = opt_compression_threshold(State),
    case byte_size(Body) >= CompressionThreshold of
        true ->
            encode_gzip_response(StatusCode, Headers, Body);
        false ->
            encode_identity_response(StatusCode, Headers, Body)
    end;
encode_response(StatusCode, Headers, Body, _State) ->
    encode_identity_response(StatusCode, Headers, Body).

-spec encode_gzip_response(http_status(), http_headers(), binary()) -> response().
encode_gzip_response(StatusCode, Headers1, Body1) ->
    Body2 = backwater_encoding_gzip:encode(Body1),
    Headers2 = Headers1#{ <<"content-encoding">> => <<"gzip">> },
    #{ status_code => StatusCode, headers => Headers2, body => Body2 }.

-spec encode_identity_response(http_status(), http_headers(), binary()) -> response().
encode_identity_response(StatusCode, Headers, Body) ->
    #{ status_code => StatusCode, headers => Headers, body => Body }.

-spec nocache_headers() -> http_headers().
nocache_headers() ->
    #{ <<"cache-control">> => <<"private, no-cache, no-store, must-revalidate">>,
       <<"pragma">> => <<"no-cache">>,
       <<"expires">> => <<"0">> }.

-spec opt_compression_threshold(state()) -> non_neg_integer().
opt_compression_threshold(State) ->
    config_opt(compression_threshold, State, ?DEFAULT_OPT_COMPRESSION_THRESHOLD).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec validate_config_pair({term(), term()}) -> boolean().
validate_config_pair({secret, Secret}) ->
    is_binary(Secret);
validate_config_pair({exposed_modules, ExposedModules}) ->
    % TODO validate deeper
    is_list(ExposedModules);
validate_config_pair({compression_threshold, CompressionThreshold}) ->
    ?is_non_neg_integer(CompressionThreshold);
validate_config_pair({decode_unsafe_terms, DecodeUnsafeTerms}) ->
    is_boolean(DecodeUnsafeTerms);
validate_config_pair({max_encoded_args_size, MaxEncodedArgsSize}) ->
    ?is_non_neg_integer(MaxEncodedArgsSize);
validate_config_pair({recv_timeout, RecvTimeout}) ->
    ?is_timeout(RecvTimeout);
validate_config_pair({return_exception_stacktraces, ReturnExceptionStacktraces}) ->
    is_boolean(ReturnExceptionStacktraces);
validate_config_pair({_Key, _Value}) ->
    false.

config_opt(Key, State, Default) ->
    #{ config := Config } = State,
    maps:get(Key, Config, Default).