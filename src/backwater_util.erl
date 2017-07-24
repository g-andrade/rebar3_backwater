-module(backwater_util).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([copies/2]).
-export([fast_catch/2]).
-export([lists_anymap/2]).
-export([lists_enumerate/1]).
-export([lists_intersect/1]).
-export([lists_keyupdate_with/5]).
-export([maps_mapfold/3]).
-export([proplists_sort_and_merge/2]).
-export([purge_stacktrace_below/2]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

copies(_Value, 0) ->
    [];
copies(Value, Count) ->
    copies_recur([Value], Count).

-spec fast_catch(Function :: fun ((...) -> term()), Args :: [term()]) -> term().
fast_catch(Function, Args) ->
    try
        apply(Function, Args)
    catch
        Class:Exception ->
            {error, {Class, Exception}}
    end.

-spec lists_anymap(Fun :: fun((term()) -> {true, term()} | true | false), [term()])
        -> {true, term()} | false.
lists_anymap(_Fun, []) ->
    false;
lists_anymap(Fun, [H|T]) ->
    case Fun(H) of
        {true, MappedH} -> {true, MappedH};
        true -> {true, H};
        false -> lists_anymap(Fun, T)
    end.

lists_enumerate(List) ->
    lists:zip(lists:seq(1, length(List)), List).

lists_intersect(Lists) ->
    Ordsets = lists:map(fun ordsets:from_list/1, Lists),
    ordsets:to_list( ordsets:intersection(Ordsets) ).

-spec lists_keyupdate_with(term(), pos_integer(), [tuple()], fun ((tuple()) -> tuple()), tuple())
        -> [tuple()].
lists_keyupdate_with(Key, N, TupleList, Fun, Initial) ->
    case lists:keyfind(Key, N, TupleList) of
        Tuple when is_tuple(Tuple) ->
            NewTuple = Fun(Tuple),
            lists:keystore(Key, N, TupleList, NewTuple);
        false ->
            lists:keystore(Key, N, TupleList, Initial)
    end.

maps_mapfold(Fun, Acc0, Map) ->
    List = maps:to_list(Map),
    {MappedList, AccN} =
        lists:mapfoldl(
          fun ({K, V1}, Acc1) ->
                  {V2, Acc2} = Fun(K, V1, Acc1),
                  {{K, V2}, Acc2}
          end,
          Acc0,
          List),
    MappedMap = maps:from_list(MappedList),
    {MappedMap, AccN}.

proplists_sort_and_merge(List1, List2) ->
    SortedList1 = lists:usort(fun proplists_element_cmp/2, lists:reverse(List1)),
    SortedList2 = lists:usort(fun proplists_element_cmp/2, lists:reverse(List2)),
    lists:merge(fun proplists_element_cmp/2, SortedList2, SortedList1).

-spec purge_stacktrace_below({module(),atom(),arity()}, [erlang:stack_item()])
        -> [erlang:stack_item()].
purge_stacktrace_below(MarkerMFA, Stacktrace) ->
    lists:takewhile(
      fun ({M,F,A,_Location}) -> {M,F,A} =/= MarkerMFA end,
      Stacktrace).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

copies_recur(Acc, Count) when Count < 2 ->
    Acc;
copies_recur([Value | _] = Acc, Count) ->
    copies_recur([Value | Acc], Count - 1).

proplists_element_cmp(A, B) ->
    proplists_element_key(A) =< proplists_element_key(B).

proplists_element_key(Atom) when is_atom(Atom) ->
    Atom;
proplists_element_key({Key, _Value}) ->
    Key.
