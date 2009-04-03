#!/bin/sh


PATHS=`grep TRACE test.[0-9]*/log.client* | cut -d '|' -f 1 | cut -d : -f 2- | sort -u | wc -l`

echo
echo "Tested $PATHS leaves"
echo

grep TRACE test.[0-9]*/log.client* | sort -u

echo
echo "Surely missing leaves (there may be more paths for the same leaf):"
echo

tmpa=`mktemp`
tmpb=`mktemp`

grep -n 'return *( *trace' smd-client | cut -d : -f 1 | sed 's/ //g' > $tmpa
grep TRACE test.[0-9]*/log.client* | sort -u | cut -d : -f 4 |\
	cut -d \| -f 1 | sed 's/ //g' > $tmpb
for N in `combine $tmpa not $tmpb`; do
	awk \
	"{L++} L==$N {\$1=\$2=\$3=\"\";print \"smd-client: \" L \":\" \$0 }" \
	smd-client
done
rm $tmpa $tmpb
