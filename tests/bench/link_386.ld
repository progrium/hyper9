/* Text at UTZERO plus the a.out header (aout.zig's layout), everything in
   one read-only segment. */
ENTRY(_start)
SECTIONS {
    . = 0x1020;
    .text 0x1020 : { *(.text.start) }
    /* The rest at its own alignment (16 for some constants); objcopy
       fills the gap. */
    .text.rest ALIGN(16) : { *(.text*) *(.rodata*) *(.srodata*) }
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
