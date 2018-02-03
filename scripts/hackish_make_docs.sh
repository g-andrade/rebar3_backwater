#!/usr/bin/env bash
set -ex

# sigh.....
rebar3 as generate_documentation compile
mkdir -p _build/generate_documentation/lib/rebar3_backwater/doc/
cp -p overview.edoc _build/generate_documentation/lib/rebar3_backwater/doc/
erl -pa _build/generate_documentation/lib/*/ebin -noshell -run edoc_run application "rebar3_backwater"
erl -pa _build/generate_documentation/lib/*/ebin -noshell -run edoc_run application "rebar3_backwater" '[{doclet, edown_doclet}, {top_level_readme, {"README.md", "https://github.com/g-andrade/rebar3_backwater", "master"}}]'
rm -rf doc
mv _build/generate_documentation/lib/rebar3_backwater/doc ./
sed -i -e 's/^\(---------\)$/\n\1/g' README.md
rm doc/*.{html,css,png,edoc} doc/edoc-info
