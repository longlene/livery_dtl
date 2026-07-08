-module(livery_dtl).
-moduledoc """
Render ErlyDTL (Django) templates as Livery responses.

A view is a plain BEAM module produced by the ErlyDTL compiler,
either at build time (rebar3_erlydtl_plugin compiling
`src/views/*.dtl` into `<name>_dtl` modules) or at boot via
`compile_dir/1,2`. `render/2,3` calls the view's `render/2` and
wraps the result as an immutable `#livery_resp{}`:

```erlang
show_user(Req) ->
    Name = livery_req:binding(<<"name">>, Req, <<"stranger">>),
    livery_dtl:render(user_dtl, #{name => Name}).
```

A missing view module maps to a 404 response, a failed render to a
500; both are logged. ErlyDTL auto-escapes variable output by
default, matching Django semantics.

Only compile templates that ship with the application. Compiling a
path influenced by request input executes attacker-controlled code.
""".

-include_lib("kernel/include/logger.hrl").

-export([
    render/2,
    render/3,

    compile_dir/1,
    compile_dir/2,

    view_module/1
]).

-export_type([vars/0, render_opts/0]).

-doc "Template variables, as accepted by ErlyDTL's generated `render/2`.".
-type vars() :: map() | [{atom() | binary() | string(), term()}].

-doc """
Rendering options.

- `status`: response status, default 200.
- `headers`: extra response headers; `content-type` defaults to
  `text/html; charset=utf-8`.
- `render_options`: passed through as ErlyDTL `RenderOptions`
  (e.g. `{locale, "sv"}`, `{translation_fun, F}`).
""".
-type render_opts() :: #{
    status => 100..599,
    headers => [{binary(), binary()}],
    render_options => [term()]
}.

%%====================================================================
%% Rendering
%%====================================================================

-doc "Render a compiled view module as a `200 text/html` response.".
-spec render(module(), vars()) -> livery_resp:resp().
render(View, Vars) ->
    render(View, Vars, #{}).

-doc "`render/2` with status, extra headers, and ErlyDTL render options.".
-spec render(module(), vars(), render_opts()) -> livery_resp:resp().
render(View, Vars, Opts) ->
    case code:ensure_loaded(View) of
        {module, View} ->
            do_render(View, Vars, Opts);
        {error, Reason} ->
            ?LOG_ERROR(#{
                msg => "livery_dtl_view_not_found",
                view => View,
                reason => Reason
            }),
            not_found()
    end.

%%====================================================================
%% Compilation
%%====================================================================

-doc """
Compile every `*.dtl` file in `Dir` into a `<basename>_dtl` module.

Modules are loaded into the VM without writing `.beam` files, so
this fits a boot-time call from your application's `start/2`. `Dir`
becomes the ErlyDTL `doc_root`, which makes `{% extends %}` and
`{% include %}` resolve against sibling templates.
""".
-spec compile_dir(file:name_all()) -> {ok, [module()]} | {error, term()}.
compile_dir(Dir) ->
    compile_dir(Dir, []).

-doc "`compile_dir/1` with extra ErlyDTL compile options appended.".
-spec compile_dir(file:name_all(), [term()]) -> {ok, [module()]} | {error, term()}.
compile_dir(Dir, ExtraOpts) ->
    Files = lists:sort(filelib:wildcard(filename:join(Dir, "*.dtl"))),
    Opts = [{doc_root, Dir}, {out_dir, false}, return | ExtraOpts],
    compile_files(Files, Opts, []).

-doc """
The view module a template file compiles to: `user.dtl` gives
`user_dtl`, matching the rebar3_erlydtl_plugin convention.
""".
-spec view_module(file:name_all()) -> module().
view_module(File) ->
    Base = filename:basename(File, ".dtl"),
    list_to_atom(unicode:characters_to_list(Base) ++ "_dtl").

%%====================================================================
%% Internal
%%====================================================================

-spec do_render(module(), vars(), render_opts()) -> livery_resp:resp().
do_render(View, Vars, Opts) ->
    RenderOpts = maps:get(render_options, Opts, []),
    try View:render(Vars, RenderOpts) of
        {ok, Html} ->
            Status = maps:get(status, Opts, 200),
            Headers = maps:get(headers, Opts, []),
            livery_resp:html(Status, Headers, Html);
        {error, Reason} ->
            ?LOG_ERROR(#{
                msg => "livery_dtl_render_failed",
                view => View,
                reason => Reason
            }),
            internal_error()
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR(#{
                msg => "livery_dtl_render_crashed",
                view => View,
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            internal_error()
    end.

-spec compile_files([file:name_all()], [term()], [module()]) ->
    {ok, [module()]} | {error, term()}.
compile_files([], _Opts, Acc) ->
    {ok, lists:reverse(Acc)};
compile_files([File | Rest], Opts, Acc) ->
    Module = view_module(File),
    case erlydtl:compile_file(File, Module, Opts) of
        {ok, Module} ->
            compile_files(Rest, Opts, [Module | Acc]);
        {ok, Module, Warnings} ->
            log_warnings(File, Warnings),
            compile_files(Rest, Opts, [Module | Acc]);
        error ->
            {error, {template_compile_failed, File}};
        {error, Errors, Warnings} ->
            log_warnings(File, Warnings),
            {error, {template_compile_failed, File, Errors}}
    end.

-spec log_warnings(file:name_all(), [term()]) -> ok.
log_warnings(_File, []) ->
    ok;
log_warnings(File, Warnings) ->
    ?LOG_WARNING(#{
        msg => "livery_dtl_compile_warnings",
        file => File,
        warnings => Warnings
    }).

-spec not_found() -> livery_resp:resp().
not_found() ->
    livery_resp:html(404, <<"<h1>Not Found</h1>">>).

-spec internal_error() -> livery_resp:resp().
internal_error() ->
    livery_resp:html(500, <<"<h1>Internal Server Error</h1>">>).
