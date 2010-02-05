#!/bin/bash

TOKILL=""
ORIGPATH=$PATH
BASE=$PWD
ROOT=$PWD/tests.d/run/client-server/

out(){
	(
	for P in $TOKILL; do
		kill $P
	done
	) 2>/dev/null
}

test_eq(){
	if diff -ruN $1 $2 >/dev/null; then
		echo -n .
	else
		echo ERROR: diff
		exit 1
	fi
}

prepare(){
	local N=$1
	cd $BASE
	rm -rf $ROOT/test.$N
	mkdir -p $ROOT/test.$N/target
	make --quiet
	make --quiet install-bin PREFIX=$ROOT/test.$N
	
	cd $ROOT/test.$N
	tar -xzf $BASE/misc/Mail.testcase.tgz
	mkfifo s2c
	mkfifo c2s

	export HOMEC=$PWD/target
	export HOMES=$PWD
	export PATH=$PWD/bin:$ORIGPATH
	export LUA_INIT="package.path='$ROOT/test.$N/share/lua/5.1/?.lua;'"
}

if [ ! -z "$1" ] && [ "$1" = "-v" ]; then
	VERBOSE=1
	shift
else
	VERBOSE=0
fi

trap out EXIT
. $BASE/tests.d/client-server/common
if [ ! -z "$1" ] && [ -f $1 ]; then
	echo -n "running `basename $1`: "
	N=`echo $1 | sed 's/^[^0-9]*\([0-9][0-9]*\).*$/\1/'`
	prepare $N
	cd $ROOT/test.$N
	. $1
	echo OK
else
	for T in $BASE/tests.d/client-server/[0-9]*; do
		echo -n "running `basename $T`: "
		N=`echo $T | sed 's/^[^0-9]*\([0-9][0-9]*\).*$/\1/'`
		prepare $N
		cd $ROOT/test.$N
		. $T
		echo OK
	done
fi

