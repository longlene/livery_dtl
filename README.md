# livery_dtl

ErlyDTL (Django template language) rendering for
[Livery](https://github.com/benoitc/livery). A view is a plain BEAM
module produced by the ErlyDTL compiler; `livery_dtl:render/2,3`
calls it and wraps the output as a `#livery_resp{}`, so template
pages are served over HTTP/1.1, HTTP/2, and HTTP/3 like any other
Livery response.

## Install

```erlang
{deps, [
    livery,
    livery_dtl
]}.
```

## Write a template

`src/views/layout.dtl`:

```django
<html><body>{% block content %}{% endblock %}</body></html>
```

`src/views/user.dtl`:

```django
{% extends "layout.dtl" %}
{% block content %}<h1>Hello {{ name }}</h1>{% endblock %}
```

## Compile the templates

Two options.

**At boot**, from your application's `start/2`:

```erlang
{ok, _Modules} = livery_dtl:compile_dir("src/views").
```

Each `*.dtl` file becomes a `<basename>_dtl` module, loaded into
the VM without writing beam files. The directory is the ErlyDTL
`doc_root`, so `{% extends %}` and `{% include %}` resolve against
sibling templates.

**At build time**, with the rebar3 plugin (same convention Nova
uses; the compiled modules are identical):

```erlang
{plugins, [
    {rebar3_erlydtl_plugin, ".*",
     {git, "https://github.com/erlydtl/rebar3_erlydtl_plugin.git",
      {ref, "f1ed9486"}}}
]}.
{erlydtl_opts, [{doc_root, "src/views"}]}.
{provider_hooks, [{pre, [{compile, {erlydtl, compile}}]}]}.
```

## Render from a handler

```erlang
show_user(Req) ->
    Name = livery_req:binding(<<"name">>, Req, <<"stranger">>),
    livery_dtl:render(user_dtl, #{name => Name}).
```

`render/3` takes options:

```erlang
livery_dtl:render(user_dtl, Vars, #{
    status => 201,
    headers => [{<<"x-frame-options">>, <<"DENY">>}],
    render_options => [{locale, "sv"}]
}).
```

A missing view module returns a 404 response, a failed render a
500; both are logged via `logger`.

## Reload templates in development

```erlang
{ok, _Pid} = livery_dtl_reload:start_link(#{dir => "src/views"}).
```

Polls the directory (default every second) and recompiles all
templates when any of them changes. Development only; compile at
build or boot time in production.

## Security notes

- ErlyDTL auto-escapes variable output by default, matching Django.
  Anything routed through the `safe` filter or an
  `{% autoescape off %}` block is your responsibility.
- Templates compile to code. Only compile paths that ship with your
  application; never a path influenced by request input.

## License

Apache-2.0
