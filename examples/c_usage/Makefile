CC = cc
CFLAGS = -Wall -Wextra -I../../zig-out/include
LDFLAGS = -L../../zig-out/lib -lzdl

main: main.c
	$(CC) $(CFLAGS) -o main main.c $(LDFLAGS)

.PHONY: clean

clean:
	rm -f main
