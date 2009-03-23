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
	cd $ROOT/test
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
	
	rm -rf test
	mkdir test
	cd test
	tar -xzf ../Mail.testcase.tgz
	
	mkfifo s2c
	mkfifo c2s
	mkdir -p target/Mail/new
	mkdir -p target/Mail/cur
	mkdir -p target/Mail/tmp

	trap out EXIT
}

conclude(){
	cd $ROOT/test
	test_eq Mail target/Mail
	cd ..
	rm -rf test
}

if [ -f $1 ]; then
	echo "running $T"
	prepare
	cd $ROOT
	. $1
	conclude
else
	for T in tests.d/*; do
		echo "running $T"
		prepare
		cd $ROOT
		. $T
		conclude
	done
fi

