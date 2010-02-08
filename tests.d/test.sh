#!/bin/bash

SUITES="client-server pull-push"
BASE=$PWD

. $BASE/tests.d/common

for TESTSUITE in $SUITES; do
	run_tests $@
done
for TESTSUITE in $SUITES; do
	if [ -x $BASE/tests.d/$TESTSUITE/summarize.sh -a -z "$1" ]; then
		BASE=$BASE $BASE/tests.d/$TESTSUITE/summarize.sh
	fi
done
