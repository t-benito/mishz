#!/bin/bash

cd "$(dirname "$0")"

passed="true"

for file in ./sema/*; do
  echo
  echo "--------------------file $file--------------------"
  echo
  ../../zig-out/bin/mishz $file
  err=$?

  if [[ "$file" == "./sema/10_if.msh" || "$file" == "./sema/09_forward_reference.msh" ]] && [[ $err == 1 ]]; then
    passed="false"
  elif [[ $file != "./sema/09_forward_reference.msh" && $file != "./sema/10_if.msh" ]] && [[ $err == 0 ]]; then
    passed="false"
  fi
done

if [[ $passed == "false" ]]; then
  echo "did not pass all tests"
else
  echo "passed all tests"
fi
