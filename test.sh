#!/bin/sh

export PATH="$PATH:$PWD"
TOKILL=""

out(){
	rm -rf s2c c2s target
	for P in $TOKILL; do
		kill $P
	done
}

make clean
make

mkfifo s2c
mkfifo c2s
mkdir -p target/Mail

smd-server.lua test Mail < c2s | tee log.s2c > s2c &
TOKILL="$TOKILL $!"

cd target 
smd-client.lua < ../s2c | tee ../log.c2s > ../c2s &
TOKILL="$TOKILL $!"

cd ..

xterm -e 'tail -f log.s2c' &
TOKILL="$TOKILL $!"

xterm -e 'tail -f log.c2s' &
TOKILL="$TOKILL $!"

trap out EXIT

echo 'Enter to exit'
read FOO
