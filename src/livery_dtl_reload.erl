-module(livery_dtl_reload).
-moduledoc """
Development-mode template reloader.

Polls a template directory and, when any `*.dtl` file appears,
disappears, or changes its mtime, recompiles the whole directory
via `livery_dtl:compile_dir/2` with `force_recompile`. The full
recompile keeps `{% extends %}`/`{% include %}` parents and
children consistent without tracking the dependency graph.

Start it from your dev shell or a dev-only supervisor:

```erlang
{ok, _Pid} = livery_dtl_reload:start_link(#{dir => "src/views"}).
```

Not intended for production; compile templates at build or boot
time there.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-doc """
Reloader options.

- `dir` (required): the template directory, also the `doc_root`.
- `interval`: poll interval in milliseconds, default 1000.
- `options`: extra ErlyDTL compile options for the recompile.
""".
-type opts() :: #{
    dir := file:name_all(),
    interval => pos_integer(),
    options => [term()]
}.

-export_type([opts/0]).

-type state() :: #{
    dir := file:name_all(),
    interval := pos_integer(),
    options := [term()],
    mtimes := #{file:name_all() => file:date_time()}
}.

-spec start_link(opts()) -> gen_server:start_ret().
start_link(#{dir := _} = Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-spec init(opts()) -> {ok, state()}.
init(Opts) ->
    State = #{
        dir => maps:get(dir, Opts),
        interval => maps:get(interval, Opts, 1000),
        options => maps:get(options, Opts, []),
        mtimes => scan(maps:get(dir, Opts))
    },
    schedule(State),
    {ok, State}.

-spec handle_call(term(), gen_server:from(), state()) ->
    {reply, {error, unsupported}, state()}.
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(tick, State) ->
    State1 = maybe_reload(State),
    schedule(State1),
    {noreply, State1};
handle_info(_Info, State) ->
    {noreply, State}.

-spec schedule(state()) -> ok.
schedule(#{interval := Interval}) ->
    _ = erlang:send_after(Interval, self(), tick),
    ok.

-spec maybe_reload(state()) -> state().
maybe_reload(#{dir := Dir, options := Opts, mtimes := Old} = State) ->
    case scan(Dir) of
        Old ->
            State;
        New ->
            case livery_dtl:compile_dir(Dir, [force_recompile | Opts]) of
                {ok, Modules} ->
                    ?LOG_INFO(#{
                        msg => "livery_dtl_reloaded",
                        dir => Dir,
                        modules => Modules
                    });
                {error, Reason} ->
                    ?LOG_ERROR(#{
                        msg => "livery_dtl_reload_failed",
                        dir => Dir,
                        reason => Reason
                    })
            end,
            State#{mtimes := New}
    end.

-spec scan(file:name_all()) -> #{file:name_all() => file:date_time()}.
scan(Dir) ->
    maps:from_list(
        [
            {File, filelib:last_modified(File)}
         || File <- filelib:wildcard(filename:join(Dir, "*.dtl"))
        ]
    ).
