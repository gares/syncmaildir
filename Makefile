BINARIES=mddiff
MANPAGES=mddiff.1 smd-server.1 smd-client.1 smd-pull.1 
PREFIX=usr/local
DESTDIR=
VERSION=0.9

all: check-build $(BINARIES) $(MANPAGES)

%: %.c
	gcc -Wall -Wextra -g $< -o $@ \
		`pkg-config --cflags --libs glib-2.0 openssl`

check-build: check-w-txt2man check-w-gcc
check-run: check-w-lua5.1 check-w-bash 

check-w-%:
	@which $* > /dev/null || echo $* not found

test: all check-run Mail.testcase.tgz
	@tests.d/test.sh $T
	@tests.d/check.sh
	@rm -rf test.[0-9]*/

Mail.testcase.tgz: 
	$(MAKE) check-w-polygen
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
	rm -f smd-$(VERSION) smd-$(VERSION).tar.gz

dist:
	$(MAKE) clean
	mkdir smd-$(VERSION)
	for X in *; do if [ $$X != smd-$(VERSION) ]; then \
		cp -r $$X smd-$(VERSION); fi; done;
	tar -cvzf smd-$(VERSION).tar.gz smd-$(VERSION)
	rm -rf smd-$(VERSION)


