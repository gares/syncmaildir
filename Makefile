BINARIES=sha1maildir

all: $(BINARIES)

sha1maildir: sha1maildir.c
	gcc -Wall -Wextra -g sha1maildir.c -o sha1maildir \
		`pkg-config --cflags --libs glib-2.0 openssl`

clean: 
	rm -f $(BINARIES)
