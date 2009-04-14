#!/bin/bash

TOKILL=""
ROOT=$PWD
ORIGPATH=$PATH

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
	cd $ROOT
	rm -rf test.$N
	mkdir test.$N
	make --quiet
	make --quiet install PREFIX=$ROOT/test.$N
	
	cd test.$N
	export HOMEC=$PWD/target
	export HOMES=$PWD
	export PATH=$PWD/bin:$ORIGPATH
	tar -xzf ../Mail.testcase.tgz
	
	mkfifo s2c
	mkfifo c2s
	mkdir -p target

}

if [ ! -z "$1" ] && [ "$1" = "-v" ]; then
	VERBOSE=1
	shift
else
	VERBOSE=0
fi

trap out EXIT
. tests.d/common
if [ ! -z "$1" ] && [ -f $1 ]; then
	echo -n "running $1: "
	N=`echo $1 | sed 's/^[^0-9]*\([0-9][0-9]*\).*$/\1/'`
	prepare 
	cd $ROOT
	. $1
	echo OK
else
	for T in tests.d/[0-9]*; do
		echo -n "running $T: "
		N=`echo $T | sed 's/^[^0-9]*\([0-9][0-9]*\).*$/\1/'`
		prepare 
		cd $ROOT
		. $T
		echo OK
	done
fi

