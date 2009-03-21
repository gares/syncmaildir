#!/bin/sh

mkfifo s2c
mkfifo c2s
./smd-server.lua test Mail &
SERVER=$!
mkdir -p target/Mail
cd target 
../smd-client.lua < ../s2c > ../c2s
echo Press enter to clean; read CLEANUP
rm -rf s2c c2s target
