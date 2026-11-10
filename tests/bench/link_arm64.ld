/* Text at UTZERO plus the a.out header (aout.zig's layout), everything in
   one read-only segment. */
ENTRY(_start)
SECTIONS {
    . = 0x10028;
    .text 0x10028 : { *(.text.start) *(.text*) *(.rodata*) *(.srodata*) }
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
