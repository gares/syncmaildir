#!/bin/bash

# set -x

SUITES=${SUITES:-"mddiff client-server pull-push benchmarks migration"}
BASE=$PWD

. $BASE/tests.d/common

for TESTSUITE in $SUITES; do
	run_tests $@
done
for TESTSUITE in $SUITES; do
	if [ -x $BASE/tests.d/$TESTSUITE/summarize.sh -a -z "$2" ]; then
		BASE=$BASE $BASE/tests.d/$TESTSUITE/summarize.sh
	fi
done
