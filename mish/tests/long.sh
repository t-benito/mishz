#!/bin/bash

cd "$(dirname "$0")"

old="~/Desktop/zig/mishz/zig-out/bin/mishz "
new="~/Desktop/zig/mishz/mish/modern/test.msh"

for i in {1..50000}; do
  old+="$new "
done

#echo run "$old"
eval "$old"
