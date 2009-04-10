BINARIES=mddiff
MANPAGES=mddiff.1

all: $(BINARIES) $(MANPAGES)

%: %.c
	gcc -Wall -Wextra -g $< -o $@ \
		`pkg-config --cflags --libs glib-2.0 openssl`

test: all Mail.testcase.tgz
	@tests.d/test.sh $T
	@tests.d/check.sh
	@rm -rf test.[0-9]*/

Mail.testcase.tgz:
	mkdir -p Mail/cur
	for i in `seq 100`; do \
		echo "Subject: `polygen /usr/share/polygen/eng/manager.grm`"\
			>> Mail/cur/$$i; \
		echo "Message-Id: $$i" >> Mail/cur/$$i; \
		echo >> Mail/cur/$$i;\
		polygen -X 10 /usr/share/polygen/eng/manager.grm\
	       		>> Mail/cur/$$i;\
	done
	tar -czf $@ Mail
	rm -rf Mail

%.1:%.1.txt
	txt2man -t $* -v "smd (Sync Mail Dir) documentation" -s 1 $< > $@

clean: 
	rm -rf $(BINARIES) test.[0-9]*/
