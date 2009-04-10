BINARIES=mddiff
MANPAGES=mddiff.1 smd-server.1 smd-client.1 smd-pull.1 
PREFIX=usr/local
DESTDIR=

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

install: all
	mkdir -p $(DESTDIR)/$(PREFIX)/bin
	mkdir -p $(DESTDIR)/$(PREFIX)/share/smd
	mkdir -p $(DESTDIR)/$(PREFIX)/share/man/1
	cp smd-common $(DESTDIR)/$(PREFIX)/share/smd
	cp mddiff smd-server smd-client smd-pull $(DESTDIR)/$(PREFIX)/bin
	cp *.1 $(DESTDIR)/$(PREFIX)/share/man/1

clean: 
	rm -rf $(BINARIES) test.[0-9]*/ *.1
