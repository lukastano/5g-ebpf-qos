# Makefile for eBPF GTP QoS

CC = clang
CFLAGS = -O2 -g -target bpf -D__TARGET_ARCH_x86
INCLUDES = -I/usr/include/x86_64-linux-gnu

SRC = src/gtp_qos.bpf.c
OBJ = gtp_qos.bpf.o

all: $(OBJ)

$(OBJ): $(SRC)
	@echo "Compiling eBPF program..."
	$(CC) $(CFLAGS) $(INCLUDES) -c $< -o $@
	@echo "Build complete: $(OBJ)"

clean:
	@echo "Cleaning..."
	rm -f $(OBJ)
	@echo "Clean complete"

install: $(OBJ)
	@echo "eBPF object ready. Use qos_manager.py to load."

.PHONY: all clean install
