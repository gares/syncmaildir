BINARIES=mddiff

all: $(BINARIES)

%: %.c
	gcc -Wall -Wextra -g $< -o $@ \
		`pkg-config --cflags --libs glib-2.0 openssl`

test:
	tests.d/test.sh $T

clean: 
	rm -rf $(BINARIES) test/ 
