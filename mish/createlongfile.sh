echo -e '\nstruct Thing { *->void(i32) fn; }' >./huge.msh
for i in {1..20000}; do
  echo -e "\npub i32 main$i {\nThing th = Thing{\n.fn=thingFn$i;\n};th.fn();\n} \n pub void thingFn$i(i32 i){\n return i*$i;\n }" >>./huge.msh
done
