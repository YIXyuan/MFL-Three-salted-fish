CC_HOST  ?= gcc
CC_CROSS ?= aarch64-linux-gnu-gcc
CFLAGS        ?= -O2 -Wall -Wextra
CFLAGS_ARM    ?= -O2 -march=armv8-a+simd -Wall -Wextra

.PHONY: all board clean test

all: pretest test_preprocess headtest test_head app

app: main.c fpga_if.c report.c preprocess.c head.c \
     fpga_if.h fpga_regs.h report.h preprocess.h head.h
	$(CC_HOST) $(CFLAGS) -o $@ main.c fpga_if.c report.c preprocess.c head.c -lm

pretest: preprocess.c preprocess.h stb_image.h
	$(CC_HOST) $(CFLAGS) -DMFL_PREPROCESS_STANDALONE -o $@ preprocess.c -lm

test_preprocess: tests/test_preprocess.c preprocess.c preprocess.h stb_image.h
	$(CC_HOST) $(CFLAGS) -o $@ tests/test_preprocess.c preprocess.c -lm

headtest: head.c head.h head_params.h
	$(CC_HOST) $(CFLAGS) -DMFL_HEAD_STANDALONE -o $@ head.c -lm

test_head: tests/test_head.c head.c head.h head_params.h
	$(CC_HOST) $(CFLAGS) -o $@ tests/test_head.c head.c -lm

test: test_preprocess test_head
	./test_preprocess tests/data/wrong_size.jpg || true
	./test_head

board: preprocess.o head.o app_arm

app_arm: main.c fpga_if.c report.c preprocess.c head.c \
         fpga_if.h fpga_regs.h report.h preprocess.h head.h
	$(CC_CROSS) $(CFLAGS_ARM) -static -o $@ main.c fpga_if.c report.c preprocess.c head.c -lm

preprocess.o: preprocess.c preprocess.h stb_image.h
	$(CC_CROSS) $(CFLAGS_ARM) -c preprocess.c -o $@

head.o: head.c head.h head_params.h
	$(CC_CROSS) $(CFLAGS_ARM) -c head.c -o $@

pretest_arm: preprocess.c preprocess.h stb_image.h
	$(CC_CROSS) $(CFLAGS_ARM) -static -DMFL_PREPROCESS_STANDALONE -o $@ preprocess.c -lm

headtest_arm: head.c head.h head_params.h
	$(CC_CROSS) $(CFLAGS_ARM) -static -DMFL_HEAD_STANDALONE -o $@ head.c -lm

clean:
	rm -f pretest test_preprocess headtest test_head app \
	      preprocess.o head.o pretest_arm headtest_arm app_arm
