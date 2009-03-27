BINARIES=mddiff

all: $(BINARIES)

%: %.c
	gcc -Wall -Wextra -g $< -o $@ \
		`pkg-config --cflags --libs glib-2.0 openssl`

test: all
	@tests.d/test.sh $T
	@tests.d/check.sh
	@rm -rf test.[0-9]*/

clean: 
	rm -rf $(BINARIES) test.[0-9]*/
