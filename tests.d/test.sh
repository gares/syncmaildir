#!/bin/bash

if [ ! -z "$1" ] && [ "$1" = "-v" ]; then
	ARGS=-v
	shift
fi

if [ ! -z "$1" ] && [ -f $1 ] && grep client-server $1; then
	tests.d/client-server/test.sh $1 $ARGS
else
	tests.d/client-server/test.sh $ARGS
fi

if [ ! -z "$1" ] && [ -f $1 ] && grep pull-push $1; then
	tests.d/pull-push/test.sh $1 $ARGS
else
	tests.d/pull-push/test.sh $ARGS
fi

