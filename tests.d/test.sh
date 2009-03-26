#!/bin/sh

export PATH="$PATH:$PWD"
TOKILL=""
ROOT=$PWD

out(){
	(
	cd $ROOT/test && rm -rf s2c c2s target
	for P in $TOKILL; do
		kill $P
	done
	) 2>/dev/null
}

test_eq(){
	cd $ROOT/test.$3
	if diff -ruN $1 $2 >/dev/null; then
		echo OK
	else
		echo ERROR
		exit 1
	fi
}

prepare(){
	cd $ROOT
	make --quiet
	
	rm -rf test.$1
	mkdir test.$1
	cd test.$1
	tar -xzf ../Mail.testcase.tgz
	
	mkfifo s2c
	mkfifo c2s
	mkdir -p target/Mail/new
	mkdir -p target/Mail/cur
	mkdir -p target/Mail/tmp

	trap out EXIT
}

conclude(){
	cd $ROOT/test.$1
	test_eq Mail target/Mail $1
	cd ..
}

if [ ! -z "$1" ] && [ "$1" = "-v" ]; then
	VERBOSE=1
	shift
else
	VERBOSE=0
fi

. tests.d/common
if [ ! -z "$1" ] && [ -f $1 ]; then
	echo -n "running $1: "
	N=`echo $1 | sed 's/^[^0-9]*\([0-9][0-9]*\).*$/\1/'`
	prepare $N
	cd $ROOT
	. $1
	conclude $N
else
	for T in tests.d/[0-9]*; do
		echo -n "running $T: "
		N=`echo $T | sed 's/^[^0-9]*\([0-9][0-9]*\).*$/\1/'`
		prepare $N
		cd $ROOT
		. $T
		conclude $N
	done
fi

