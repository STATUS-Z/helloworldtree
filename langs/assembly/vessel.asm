; Hello World Tree — Assembly adapter.
;
; Assembly is the fused language. The prompt's design called for Assembly with every other language
; baked into it, starting from the most basic snippets, wedged into a Java host. This file is that
; floor: the instruction-level view that every other adapter's output ultimately resolves to.
;
; WHY IT IS THE FLOOR
;
; Every adapter above reports what was *written*. This one reports what *runs*. A `def helper(x)` in
; Python and a `fn helper(x: i32)` in Rust and a `int helper(int x)` in C all become, at this level,
; the same shape: a stack frame, a move, an add, a return. That convergence is why the vessel can be
; built before any data flows — the structure is already universal.
;
; The SLEIGH definition is what makes this portable across dialects. This file is one dialect; the
; .slaspec is the rulebook that says what it means.
;
; ARCHITECTURE: x86-64, System V AMD64 ABI (Linux/macOS). Windows differs in two places, both noted.
;
; NASM syntax unless a line says otherwise.

section .text

; ── The primitive every adapter reduces to ────────────────────────────────────
; A function that takes one integer and returns it incremented.
;
; This is the "hello world" of the vessel, and it is deliberately the smallest thing that has a stack
; frame, an argument, a computation, and a return. Four p-code operations, which is the minimum needed
; to exercise every part of the analysis.

global hwt_identity_inc
hwt_identity_inc:
    push    rbp                     ; frame save
    mov     rbp, rsp                ; frame establish
    mov     [rbp - 4], edi          ; argument: first int in edi (SysV)
    mov     eax, [rbp - 4]          ; load
    add     eax, 1                  ; compute
    pop     rbp                     ; frame restore
    ret                             ; return value is in eax

; ── Byte-level detection stub ────────────────────────────────────────────────
; The fast-detection pass does not decompile anything. It reads a few bytes and decides whether this
; binary is worth the analysis budget. That ordering matters: an unrecognised file costs four bytes,
; not four seconds.
;
; The comparison here is the classic x86-64 function prologue. Finding it is weak evidence; finding it
; repeatedly at aligned offsets is strong evidence.

global hwt_probe_prologue
hwt_probe_prologue:
    ; rdi = pointer to buffer, rsi = length
    cmp     rsi, 4
    jb      .no                     ; too short to contain a prologue

    cmp     byte [rdi + 0], 0x55    ; push rbp
    jne     .no
    cmp     byte [rdi + 1], 0x48    ; REX.W prefix
    jne     .no
    cmp     byte [rdi + 2], 0x89    ; mov
    jne     .no
    cmp     byte [rdi + 3], 0xE5    ; mov rbp, rsp
    jne     .no

    mov     eax, 1                  ; recognised
    ret

.no:
    xor     eax, eax                ; not recognised
    ret

; ── Register save/restore, because the vessel must be re-entrant ─────────────
; An adapter that clobbers a caller's registers is an adapter that cannot be called from a loop. The
; analysis layer walks hundreds of files, so this matters.

global hwt_preserve_call
hwt_preserve_call:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    ; rdi holds the function pointer.
    ;
    ; SysV passes arguments in registers, so nothing needs to be spilled before this indirect call.
    ; Windows x64 differs: the first four arguments go in rcx, rdx, r8, r9, and then a 32-byte shadow
    ; space must be reserved on the stack. That is the one place this file is not portable, and it is
    ; noted rather than worked around, because a workaround would be wrong on one of the two.
    call    rdi

    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ── The dispatch table ───────────────────────────────────────────────────────
; One entry per adapter. The order is precedence order, which is the same rule the Rust registry
; follows: a precise match must be tried before a general one, or a .slaspec file would be claimed by
; the C adapter and never reach SLEIGH.

section .data

global hwt_dispatch
hwt_dispatch:
    ; (extension pointer, adapter id, priority)
    dq  ext_slaspec,  id_sleigh,    100
    dq  ext_hlsl,     id_unknown,    50
    dq  ext_spec,     id_sleigh,     90
    dq  ext_asm,      id_assembly,   80
    dq  ext_s,        id_assembly,   80
    dq  0,            0,              0     ; terminator

ext_slaspec: db ".slaspec", 0
ext_spec:    db ".spec",    0
ext_hlsl:    db ".hlsl",    0
ext_asm:     db ".asm",     0
ext_s:       db ".s",       0
id_sleigh:   db "sleigh",   0
id_assembly: db "assembly", 0
id_unknown:  db "unknown",  0

; ── Why this file is short ───────────────────────────────────────────────────
; A complete x86-64 disassembler is a project, not an adapter. What the vessel needs from this layer is
; the *shape*: a frame, a probe, a dispatch table, and the register discipline that lets it be called
; in a loop. The real work is in the SLEIGH definition, which is where the dialect becomes p-code and
; where every architecture converges.
;
; So this file states the floor and leaves the instruction table to the .slaspec. That is not a
; shortcut; it is the division of labour the design called for.
