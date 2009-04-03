#!/bin/sh

grep TRACE test.[0-9]*/log.client* | sort -u

PATHS=`grep TRACE test.[0-9]*/log.client* | cut -d '|' -f 1 | cut -d : -f 2- | sort -u | wc -l`
TRACES=`grep trace smd-client | grep -v ^function | wc -l`

echo "Tested $PATHS code paths out of $TRACES"


