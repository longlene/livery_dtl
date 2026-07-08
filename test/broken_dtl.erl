%% Stand-in for an ErlyDTL-generated view whose render fails.
-module(broken_dtl).

-export([render/2]).

render(#{mode := crash}, _Opts) ->
    erlang:error(boom);
render(_Vars, _Opts) ->
    {error, boom}.
