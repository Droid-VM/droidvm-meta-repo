# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright DroidVM contributors
#
# A flat aarch64 binary, freestanding, no libc, no relocations to apply at load time. crosvm
# copies shim.bin to the base of the VM's lent region and patches the header that follows the
# entry branch; nothing else knows or cares where it ended up.

CROSS   ?= aarch64-linux-gnu-
CC      := $(CROSS)gcc
LD      := $(CROSS)ld
OBJCOPY := $(CROSS)objcopy

CFLAGS := -O2 -g -std=gnu11 -ffreestanding -fno-stack-protector -fno-builtin \
          -fno-common -fno-PIE -mgeneral-regs-only -mstrict-align \
          -Wall -Wextra -Werror -Wno-unused-parameter
LDFLAGS := -T shim.ld -nostdlib --no-dynamic-linker -static

OBJS := start.o shim.o

all: shim.bin

start.o: start.S shim.h
	$(CC) $(CFLAGS) -c -o $@ $<

shim.o: shim.c shim.h
	$(CC) $(CFLAGS) -c -o $@ $<

shim.elf: $(OBJS) shim.ld
	$(LD) $(LDFLAGS) -o $@ $(OBJS) -Map=shim.map

shim.bin: shim.elf
	$(OBJCOPY) -O binary --set-section-flags .bss=alloc,load,contents $< $@
	@size=$$(stat -c%s $@); echo "shim.bin: $$size bytes"; \
	 if [ $$size -gt $$((2 * 1024 * 1024)) ]; then \
	   echo "shim.bin does not fit the 2 MiB the boot region gives it"; exit 1; fi

clean:
	rm -f $(OBJS) shim.elf shim.bin shim.map

.PHONY: all clean

# Offline check of the device-tree walk and the /memory rewrite, against a tree shaped like the
# one the resource manager hands over. aarch64 because that is the shim's only target; qemu-user
# because this machine is not one.
test: test/sample.dtb test/fdt_test.c shim.c shim.h
	$(CC) -O1 -g -std=gnu11 -static -Wall -Wno-unused-function -Wno-unused-parameter \
	      -o test/fdt_test test/fdt_test.c
	cd test && qemu-aarch64-static ./fdt_test sample.dtb

test/sample.dtb: test/sample.dts
	dtc -I dts -O dtb -o $@ $< 2>/dev/null

.PHONY: test
