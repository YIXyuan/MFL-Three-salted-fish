CROSS   ?=
CC       = $(CROSS)gcc
CFLAGS  ?= -O2 -std=c11 -Wall -Wextra
INC      = -Isrc

SRC_HEAD = src/head.c
SRC_TEST = test/test_head.c
SRC_CLI  = app/head_cli.c src/fpga_if.c
SRC_SVC  = test/test_service.c src/head_service.c

all: build/test_head build/test_head_qdq build/head_cli build/test_service

build:
	mkdir -p build

build/test_head: $(SRC_HEAD) $(SRC_TEST) src/head.h src/quant_params.h | build
	$(CC) $(CFLAGS) $(INC) -o $@ $(SRC_TEST) $(SRC_HEAD) -lm

build/test_head_qdq: $(SRC_HEAD) $(SRC_TEST) src/head.h src/quant_params.h | build
	$(CC) $(CFLAGS) $(INC) -DMFL_HEAD_QDQ=1 -o $@ $(SRC_TEST) $(SRC_HEAD) -lm

build/head_cli: $(SRC_HEAD) $(SRC_CLI) src/head.h src/fpga_if.h src/quant_params.h | build
	$(CC) $(CFLAGS) $(INC) -o $@ $(SRC_CLI) $(SRC_HEAD) -lm

build/test_service: $(SRC_HEAD) $(SRC_SVC) src/head.h src/head_service.h src/quant_params.h | build
	$(CC) $(CFLAGS) $(INC) -o $@ $(SRC_SVC) $(SRC_HEAD) -lm

test: build/test_head build/test_head_qdq
	./build/test_head weights/head_weights.bin test_vectors
	./build/test_head_qdq weights/head_weights.bin test_vectors

arm:
	$(MAKE) clean
	$(MAKE) CROSS=aarch64-linux-gnu- CFLAGS="-O3 -mcpu=cortex-a53 -std=c11 -Wall -Wextra -static" \
	        build/test_head build/head_cli build/test_service

clean:
	rm -rf build

.PHONY: all test arm clean
