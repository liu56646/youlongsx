.section .text.entry
.global _start
_start:
    adrp x0, stack_top
    add x0, x0, :lo12:stack_top
    mov sp, x0
    bl guest_main
    b .

.section .bss
.balign 4096
stack_bottom: .skip 16384
stack_top:
