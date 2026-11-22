# tools/kconfig/linux/Makefile - the Linux kernel's kconfig (scripts/kconfig of
# Linux 6.8, GPL-2.0), built outside the kernel tree:
#   conf    defconfig, oldconfig, olddefconfig, savedefconfig, all*config...
#   mconf   make menuconfig (lxdialog, ncurses)
#   nconf   make nconfig
# parser.tab.[ch] and lexer.lex.c are generated (bison, flex) and kept in the
# repository: building only needs gcc and libncurses-dev.
#   make -C tools/kconfig/linux            -> build/{conf,mconf,nconf}
#   make -C tools/kconfig/linux regen      bison + flex again
CC      ?= gcc
O       ?= build
CFLAGS  ?= -O2 -w
COMMON  := confdata.c expr.c lexer.lex.c menu.c parser.tab.c preprocess.c symbol.c util.c
LXD     := $(wildcard lxdialog/*.c)
NCURSES_CFLAGS := $(shell pkg-config --cflags ncursesw 2>/dev/null || echo -D_GNU_SOURCE -I/usr/include/ncursesw)
NCURSES_LIBS   := $(shell pkg-config --libs ncursesw 2>/dev/null || echo -lncursesw)
NC_LIBS        := $(shell pkg-config --libs menuw panelw ncursesw 2>/dev/null || echo -lmenuw -lpanelw -lncursesw)

all: $(O)/conf $(O)/mconf $(O)/nconf

$(O):
	@mkdir -p $(O)
$(O)/conf: conf.c $(COMMON) | $(O)
	$(CC) $(CFLAGS) -I. -o $@ conf.c $(COMMON)
$(O)/mconf: mconf.c mnconf-common.c $(COMMON) $(LXD) | $(O)
	$(CC) $(CFLAGS) $(NCURSES_CFLAGS) -I. -o $@ mconf.c mnconf-common.c $(COMMON) $(LXD) $(NCURSES_LIBS)
$(O)/nconf: nconf.c nconf.gui.c mnconf-common.c $(COMMON) | $(O)
	$(CC) $(CFLAGS) $(NCURSES_CFLAGS) -I. -o $@ nconf.c nconf.gui.c mnconf-common.c $(COMMON) $(NC_LIBS)

regen:
	bison -o parser.tab.c --defines=parser.tab.h -t -l parser.y
	flex -o lexer.lex.c -L lexer.l

clean:
	rm -rf $(O)
.PHONY: all regen clean
