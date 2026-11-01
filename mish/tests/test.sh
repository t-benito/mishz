#!/bin/bash

cd "$(dirname "$0")"

passed="true"

for file in ./sema/*; do
  echo
  echo "--------------------file $file--------------------"
  echo
  ../../zig-out/bin/mishz $file
  err=$?

  if [[ $file == "./sema/09_foward_reference.msh" && $err -eq 1 ]]; then
    passed="false"
  elif [[ $file != "./sema/09_forward_reference.msh" && $err -eq 0 ]]; then
    passed="false"
  fi
done

if [[ $passed == "false" ]]; then
  echo "did not pass all tests"
else
  echo "passed all tests"
fi
