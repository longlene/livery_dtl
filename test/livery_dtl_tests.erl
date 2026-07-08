-module(livery_dtl_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Fixtures
%%====================================================================

fixture_dir() ->
    Dir = filename:join(
        os:getenv("TMPDIR", "/tmp"),
        "livery_dtl_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_path(Dir),
    ok = file:write_file(
        filename:join(Dir, "layout.dtl"),
        <<"<html><body>{% block content %}{% endblock %}</body></html>">>
    ),
    ok = file:write_file(
        filename:join(Dir, "index.dtl"),
        <<
            "{% extends \"layout.dtl\" %}"
            "{% block content %}<h1>Hello {{ name }}</h1>{% endblock %}"
        >>
    ),
    Dir.

cleanup(Dir) ->
    [file:delete(F) || F <- filelib:wildcard(filename:join(Dir, "*.dtl"))],
    file:del_dir(Dir).

compile_fixtures() ->
    Dir = fixture_dir(),
    {ok, Modules} = livery_dtl:compile_dir(Dir),
    {Dir, Modules}.

body_binary(Resp) ->
    {full, IoData} = livery_resp:body(Resp),
    iolist_to_binary(IoData).

%% Failure-path tests exercise code that logs errors by design;
%% silence livery_dtl's logging so expected errors don't pollute
%% the eunit output.
silence_logs(Fun) ->
    ok = logger:set_module_level(livery_dtl, none),
    try
        Fun()
    after
        logger:unset_module_level(livery_dtl)
    end.

%%====================================================================
%% compile_dir
%%====================================================================

compile_dir_test() ->
    {Dir, Modules} = compile_fixtures(),
    ?assertEqual([index_dtl, layout_dtl], Modules),
    cleanup(Dir).

compile_dir_error_test() ->
    Dir = fixture_dir(),
    ok = file:write_file(
        filename:join(Dir, "bad.dtl"),
        <<"{% block unclosed %}">>
    ),
    ?assertMatch(
        {error, {template_compile_failed, _, _}},
        livery_dtl:compile_dir(Dir)
    ),
    cleanup(Dir).

view_module_test() ->
    ?assertEqual(user_dtl, livery_dtl:view_module("src/views/user.dtl")).

%%====================================================================
%% render
%%====================================================================

render_test() ->
    {Dir, _} = compile_fixtures(),
    Resp = livery_dtl:render(index_dtl, #{name => <<"world">>}),
    ?assertEqual(200, livery_resp:status(Resp)),
    ?assertEqual(
        {<<"content-type">>, <<"text/html; charset=utf-8">>},
        lists:keyfind(<<"content-type">>, 1, livery_resp:headers(Resp))
    ),
    ?assertEqual(
        <<"<html><body><h1>Hello world</h1></body></html>">>,
        body_binary(Resp)
    ),
    cleanup(Dir).

render_opts_test() ->
    {Dir, _} = compile_fixtures(),
    Resp = livery_dtl:render(index_dtl, #{name => <<"x">>}, #{
        status => 201,
        headers => [{<<"x-extra">>, <<"1">>}]
    }),
    ?assertEqual(201, livery_resp:status(Resp)),
    ?assertEqual(
        {<<"x-extra">>, <<"1">>},
        lists:keyfind(<<"x-extra">>, 1, livery_resp:headers(Resp))
    ),
    cleanup(Dir).

autoescape_test() ->
    {Dir, _} = compile_fixtures(),
    Resp = livery_dtl:render(index_dtl, #{name => <<"a & <b>">>}),
    ?assertEqual(
        <<"<html><body><h1>Hello a &amp; &lt;b&gt;</h1></body></html>">>,
        body_binary(Resp)
    ),
    cleanup(Dir).

missing_view_test() ->
    Resp = silence_logs(fun() -> livery_dtl:render(no_such_view_dtl, #{}) end),
    ?assertEqual(404, livery_resp:status(Resp)).

render_error_test() ->
    Resp = silence_logs(fun() -> livery_dtl:render(broken_dtl, #{}) end),
    ?assertEqual(500, livery_resp:status(Resp)).

render_crash_test() ->
    Resp = silence_logs(fun() ->
        livery_dtl:render(broken_dtl, #{mode => crash})
    end),
    ?assertEqual(500, livery_resp:status(Resp)).

%%====================================================================
%% End to end through the in-memory adapter
%%====================================================================

adapter_test() ->
    {Dir, _} = compile_fixtures(),
    Cap = livery_test_adapter:run(
        [],
        fun(_Req) -> livery_dtl:render(index_dtl, #{name => <<"livery">>}) end,
        #{method => <<"GET">>, path => <<"/">>}
    ),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(
        <<"<html><body><h1>Hello livery</h1></body></html>">>,
        livery_test_adapter:body(Cap)
    ),
    cleanup(Dir).

%%====================================================================
%% Reloader
%%====================================================================

reload_test() ->
    {Dir, _} = compile_fixtures(),
    {ok, Pid} = livery_dtl_reload:start_link(#{dir => Dir, interval => 60000}),
    ok = file:write_file(
        filename:join(Dir, "index.dtl"),
        <<"{% extends \"layout.dtl\" %}{% block content %}v2 {{ name }}{% endblock %}">>
    ),
    %% Beat the 1-second mtime granularity so the scan sees a change.
    Future = calendar:gregorian_seconds_to_datetime(
        calendar:datetime_to_gregorian_seconds(calendar:universal_time()) + 5
    ),
    ok = file:change_time(filename:join(Dir, "index.dtl"), Future),
    Pid ! tick,
    %% sys:get_state is a synchronization barrier: it returns after
    %% the tick has been processed.
    _ = sys:get_state(Pid),
    Resp = livery_dtl:render(index_dtl, #{name => <<"world">>}),
    ?assertEqual(
        <<"<html><body>v2 world</body></html>">>,
        body_binary(Resp)
    ),
    unlink(Pid),
    exit(Pid, shutdown),
    cleanup(Dir).
