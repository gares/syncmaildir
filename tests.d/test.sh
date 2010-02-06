#!/bin/bash

SUITES="client-server pull-push"
BASE=$PWD

. $BASE/tests.d/common

for TESTSUITE in $SUITES; do
	run_tests $@
	if [ -x $BASE/tests.d/$TESTSUITE/summarize.sh ]; then
		BASE=$BASE $BASE/tests.d/$TESTSUITE/summarize.sh
	fi
done
