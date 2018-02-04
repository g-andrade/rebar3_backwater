

# rebar3_backwater #

[![Build Status](https://travis-ci.org/g-andrade/rebar3_backwater.png?branch=master)](https://travis-ci.org/g-andrade/rebar3_backwater)
[![Hex pm](http://img.shields.io/hexpm/v/rebar3_backwater.svg?style=flat)](https://hex.pm/packages/rebar3_backwater)


### <a name="A_rebar3_plugin_for_generating_Backwater_client_boilerplate">A rebar3 plugin for generating Backwater client boilerplate</a> ###

With `rebar3_backwater`, using `backwater` becomes easier.


### <a name="WORK_IN_PROGRESS,_UNSTABLE">WORK IN PROGRESS, UNSTABLE</a> ###


#### <a name="Usage">Usage</a> ####

<h5><a name="1._Import_the_plugin">1. Import the plugin</a></h5>
In `rebar.config`:

```erlang

{plugins, [rebar3_backwater]}.

```

<h5><a name="2._Define_target">2. Define target</a></h5>

In `rebar.config`:

```erlang


{backwater_gen,
 [{call_endpoint, {"http://localhost:8080/", <<"SECRET">>}},
  {target, {stdlib, string, [{exports,all}]}}
 ]}.


```

<h5><a name="3._Generate_the_code">3. Generate the code</a></h5>
Run in shell:

```

rebar3 backwater generate

```

"src/rpc/rpc_string.erl" will now have been created.
allowing any function in the `string` module to be
remotely called.


#### <a name="Details">Details</a> ####

<h5><a name="Requirements">Requirements</a></h5>
* Erlang/OTP 19 or higher
* rebar3
* backwater 3.x


## Modules ##


<table width="100%" border="0" summary="list of modules">
<tr><td><a href="https://github.com/g-andrade/rebar3_backwater/blob/master/doc/rebar3_backwater_generator.md" class="module">rebar3_backwater_generator</a></td></tr>
<tr><td><a href="https://github.com/g-andrade/rebar3_backwater/blob/master/doc/rebar3_backwater_util.md" class="module">rebar3_backwater_util</a></td></tr></table>

