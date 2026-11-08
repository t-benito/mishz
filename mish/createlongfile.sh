echo -e 'struct Thing { *->void(i32) fn; }' >./huge.msh
for i in {1..50000}; do
  printf "pub i32 main%d { Thing th = Thing{ .fn=thingFn%d }; th.fn(); } pub void thingFn%d(i32 i){ return i * %d; }" $i $i $i $i >>./huge.msh
done
