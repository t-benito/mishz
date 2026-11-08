#!/bin/bash

cd "$(dirname "$0")"

old="~/Desktop/zig/mishz/zig-out/bin/mishz "
new="~/Desktop/zig/mishz/huge.msh"

for i in {1..50000}; do
  old+="$new "
done

#echo run "$old"
eval "$old" >/dev/null 2>&1
