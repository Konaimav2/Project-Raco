/*
 * Project Raco - Performance and Gaming Optimization Suite
 * Assembly rewrite of the Game Assistant core (stage 1 helpers).
 *
 * These routines replace the C equivalents in RacoGameAssistant.c without
 * touching that file. Exported for tests:
 *   long long wa_now_ms(void);
 *   int  wa_read_file(const char *path, char *buf, int cap);
 *   int  wa_gamelist_reload(const char *path);   // 1 changed, 0 same, -1 error
 *   int  wa_gamelist_has(const char *pkg);       // whole-line match
 *   int  wa_instance_lock(const char *path);     // fd or -1
 *   void wa_instance_unlock(int fd);
 */

    .equ AT_FDCWD,        -100
    .equ O_RDONLY,         0
    .equ O_RDWR,           2
    .equ O_CREAT,          0100
    .equ O_CLOEXEC,        02000000
    .equ LOCK_EX,          2
    .equ LOCK_NB,          4
    .equ PERM_600,         0600
    .equ SYS_OPENAT,       56
    .equ SYS_CLOSE,        57
    .equ SYS_READ,         63
    .equ SYS_FLOCK,        32
    .equ CLOCK_MONOTONIC,  1
    .equ GAMELIST_MAX,     4096

    .bss
    .align 4
wa_tmp:             .skip GAMELIST_MAX
gamelist:           .skip GAMELIST_MAX
gamelist_len:       .skip 8
wa_out:             .skip 8

    .text
/* void wa_sleep_ms(long ms) - nanosleep syscall, no libc */
    .global wa_sleep_ms
    .type wa_sleep_ms, %function
wa_sleep_ms:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    mov x1, #1000
    udiv x2, x0, x1
    msub x3, x2, x1, x0
    movz w4, #0x4240
    movk w4, #0xf, lsl #16    // 1,000,000 ns per ms
    mul x3, x3, x4
    str x2, [sp, #16]
    str x3, [sp, #24]
.Lsl_again:
    add x0, sp, #16
    add x1, sp, #16           // remaining time lands back in the same timespec
    mov x8, #101              // SYS_nanosleep
    svc #0
    cmn x0, #4                // -EINTR: sleep the rest
    b.eq .Lsl_again
    ldp x29, x30, [sp], #32
    ret
    .size wa_sleep_ms, .-wa_sleep_ms

/* int wa_atoi(const char *s)
 * Like atoi: skips space and \t\n\v\f\r, optional sign, stops at the first
 * non-digit. Result is sign-extended to 64 bits. */
    .global wa_atoi
    .type wa_atoi, %function
wa_atoi:
    mov x1, x0
.Lai_skip:
    ldrb w2, [x1]
    cmp w2, #32
    b.eq .Lai_skip1
    sub w4, w2, #9            // \t..\r are 9..13
    cmp w4, #4
    b.hi .Lai_sign
.Lai_skip1:
    add x1, x1, #1
    b .Lai_skip
.Lai_sign:
    mov x3, #0                // negative flag
    cmp w2, #43               // '+'
    b.eq .Lai_signed
    cmp w2, #45               // '-'
    b.ne .Lai_digits
    mov x3, #1
.Lai_signed:
    add x1, x1, #1
.Lai_digits:
    mov x0, #0
.Lai_loop:
    ldrb w2, [x1]
    cmp w2, #48
    b.lt .Lai_done
    cmp w2, #57
    b.gt .Lai_done
    mov x4, #10
    mul x0, x0, x4
    sub w2, w2, #48
    add x0, x0, x2
    add x1, x1, #1
    b .Lai_loop
.Lai_done:
    cbz x3, .Lai_ret
    neg x0, x0
.Lai_ret:
    sxtw x0, w0               // int result, as atoi
    ret
    .size wa_atoi, .-wa_atoi

/* char *wa_strcpy(char *dst, const char *src) */
    .global wa_strcpy
    .type wa_strcpy, %function
wa_strcpy:
    mov x2, x0
.Lscp_loop:
    ldrb w3, [x1]
    strb w3, [x0]
    cbz w3, .Lscp_done
    add x0, x0, #1
    add x1, x1, #1
    b .Lscp_loop
.Lscp_done:
    mov x0, x2
    ret
    .size wa_strcpy, .-wa_strcpy

/* char *wa_strstr(const char *hay, const char *needle) */
    .global wa_strstr
    .type wa_strstr, %function
wa_strstr:
    mov x2, x0
.Lss_outer:
    ldrb w3, [x2]
    cbz w3, .Lss_none
    mov x4, x2
    mov x5, x1
.Lss_inner:
    ldrb w6, [x5]
    cbz w6, .Lss_found
    ldrb w7, [x4]
    cmp w6, w7
    b.ne .Lss_next
    add x4, x4, #1
    add x5, x5, #1
    b .Lss_inner
.Lss_next:
    add x2, x2, #1
    b .Lss_outer
.Lss_found:
    mov x0, x2
    ret
.Lss_none:
    mov x0, #0
    ret
    .size wa_strstr, .-wa_strstr

/* void wa_put_start(char *buf) */
    .global wa_put_start
    .type wa_put_start, %function
wa_put_start:
    adrp x1, wa_out
    add x1, x1, :lo12:wa_out
    str x0, [x1]
    ret
    .size wa_put_start, .-wa_put_start

/* void wa_put_str(const char *s) */
    .global wa_put_str
    .type wa_put_str, %function
wa_put_str:
    adrp x1, wa_out
    add x1, x1, :lo12:wa_out
    ldr x1, [x1]
.Lps_loop:
    ldrb w2, [x0]
    cbz w2, .Lps_done
    strb w2, [x1]
    add x0, x0, #1
    add x1, x1, #1
    b .Lps_loop
.Lps_done:
    strb wzr, [x1]
    adrp x2, wa_out
    add x2, x2, :lo12:wa_out
    str x1, [x2]
    ret
    .size wa_put_str, .-wa_put_str

/* void wa_put_dec(long v) - unsigned decimal, enough for pids/modes/freqs */
    .global wa_put_dec
    .type wa_put_dec, %function
wa_put_dec:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    add x1, sp, #47           // write digits backwards, clear of x29/x30
    mov x2, #0
    mov x3, #10
.Lpd_loop:
    udiv x4, x0, x3
    msub x5, x4, x3, x0
    add w5, w5, #48
    strb w5, [x1, #-1]!
    add x2, x2, #1
    mov x0, x4
    cbnz x0, .Lpd_loop
    // copy digits forward
    adrp x6, wa_out
    add x6, x6, :lo12:wa_out
    ldr x6, [x6]
.Lpd_copy:
    ldrb w5, [x1], #1
    strb w5, [x6], #1
    subs x2, x2, #1
    b.ne .Lpd_copy
    strb wzr, [x6]
    adrp x7, wa_out
    add x7, x7, :lo12:wa_out
    str x6, [x7]
    ldp x29, x30, [sp], #48
    ret
    .size wa_put_dec, .-wa_put_dec


    .global wa_now_ms
    .type wa_now_ms, %function
wa_now_ms:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    mov x0, #CLOCK_MONOTONIC
    add x1, sp, #16          // timespec must not overlap saved x29/x30
    mov x8, #113             // SYS_clock_gettime
    svc #0
    ldr x0, [sp, #16]        // tv_sec
    ldr x1, [sp, #24]        // tv_nsec
    movz x2, #0x4240
    movk x2, #0xf, lsl #16   // 1,000,000 ns per ms
    udiv x1, x1, x2
    mov x2, #1000
    mul x0, x0, x2
    add x0, x0, x1
    ldp x29, x30, [sp], #32
    ret
    .size wa_now_ms, .-wa_now_ms

/* int wa_read_file(const char *path, char *buf, int cap)
 * returns bytes read, or -1 on any error. NUL-terminates when cap > 0. */
    .global wa_read_file
    .type wa_read_file, %function
wa_read_file:
    stp x29, x30, [sp, #-48]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x29, sp
    mov x19, x0             // path
    mov x20, x1             // buf
    mov x21, x2             // cap

    mov x0, #AT_FDCWD
    mov x1, x19
    mov x2, #O_RDONLY
    mov x3, #0
    mov x8, #SYS_OPENAT
    svc #0
    cmp x0, #0
    b.lt .Lrf_fail
    mov x22, x0             // fd

    mov x0, x22
    mov x1, x20
    mov x2, x21
    mov x8, #SYS_READ
    svc #0
    cmp x0, #0
    b.lt .Lrf_close_fail
    mov x19, x0             // len

    mov x0, x22
    mov x8, #SYS_CLOSE
    svc #0

    // NUL-terminate inside cap
    cmp x21, #1
    b.lt .Lrf_ok
    sub x1, x21, #1
    cmp x19, x1
    b.le .Lrf_term
    mov x19, x1
.Lrf_term:
    strb wzr, [x20, x19]
.Lrf_ok:
    mov x0, x19
    b .Lrf_out

.Lrf_close_fail:
    mov x0, x22
    mov x8, #SYS_CLOSE
    svc #0
.Lrf_fail:
    mov x0, #-1
.Lrf_out:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
    .size wa_read_file, .-wa_read_file

/* int wa_gamelist_reload(const char *path)
 * Reads the list into a temp buffer, swaps it in only when it changed. */
    .global wa_gamelist_reload
    .type wa_gamelist_reload, %function
wa_gamelist_reload:
    stp x29, x30, [sp, #-48]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x29, sp

    adrp x1, wa_tmp
    add x1, x1, :lo12:wa_tmp
    mov x2, #GAMELIST_MAX
    sub x2, x2, #1
    bl wa_read_file
    cmp x0, #0
    b.lt .Lgr_err
    mov x19, x0             // new len

    adrp x20, gamelist
    add x20, x20, :lo12:gamelist
    adrp x21, gamelist_len
    add x21, x21, :lo12:gamelist_len
    ldr x22, [x21]          // old len

    cmp x19, x22
    b.ne .Lgr_changed

    // same length: compare bytes
    adrp x3, wa_tmp
    add x3, x3, :lo12:wa_tmp
    mov x4, #0
.Lgr_cmp:
    cmp x4, x19
    b.hs .Lgr_same
    ldrb w5, [x20, x4]
    ldrb w6, [x3, x4]
    cmp w5, w6
    b.ne .Lgr_changed
    add x4, x4, #1
    b .Lgr_cmp

.Lgr_same:
    mov x0, #0
    b .Lgr_out

.Lgr_changed:
    adrp x3, wa_tmp
    add x3, x3, :lo12:wa_tmp
    mov x4, #0
.Lgr_copy:
    cmp x4, x19
    b.hs .Lgr_copied
    ldrb w5, [x3, x4]
    strb w5, [x20, x4]
    add x4, x4, #1
    b .Lgr_copy
.Lgr_copied:
    strb wzr, [x20, x19]
    str x19, [x21]
    mov x0, #1
    b .Lgr_out

.Lgr_err:
    mov x0, #-1
.Lgr_out:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
    .size wa_gamelist_reload, .-wa_gamelist_reload

/* int wa_gamelist_has(const char *pkg)
 * Whole-line match, trailing CR ignored, matching check_game_in_memory(). */
    .global wa_gamelist_has
    .type wa_gamelist_has, %function
wa_gamelist_has:
    adrp x1, gamelist
    add x1, x1, :lo12:gamelist
    adrp x2, gamelist_len
    add x2, x2, :lo12:gamelist_len
    ldr x2, [x2]
    add x3, x1, x2          // end of buffer

.Lgh_line:
    cmp x1, x3
    b.hs .Lgh_no
    mov x4, x1              // line start
.Lgh_nl:
    cmp x1, x3
    b.hs .Lgh_end_at_end
    ldrb w5, [x1]
    cmp w5, #10
    b.eq .Lgh_have_end
    add x1, x1, #1
    b .Lgh_nl

.Lgh_end_at_end:
    mov x5, x1              // line end == buffer end
    b .Lgh_trim

.Lgh_have_end:
    mov x5, x1              // line end at newline

.Lgh_trim:
    cmp x5, x4
    b.le .Lgh_next
    ldrb w6, [x5, #-1]
    cmp w6, #13
    b.ne .Lgh_cmp_start
    sub x5, x5, #1

.Lgh_cmp_start:
    mov x6, x4              // ptr in line
    mov x7, x0              // ptr in pkg
.Lgh_cmp:
    cmp x6, x5
    b.hs .Lgh_cmp_end
    ldrb w8, [x6]
    ldrb w9, [x7]
    cmp w8, w9
    b.ne .Lgh_next
    add x6, x6, #1
    add x7, x7, #1
    b .Lgh_cmp
.Lgh_cmp_end:
    ldrb w9, [x7]
    cbz w9, .Lgh_yes

.Lgh_next:
    cmp x1, x3
    b.hs .Lgh_no
    add x1, x1, #1
    b .Lgh_line

.Lgh_yes:
    mov x0, #1
    ret
.Lgh_no:
    mov x0, #0
    ret
    .size wa_gamelist_has, .-wa_gamelist_has

/* int wa_instance_lock(const char *path)
 * Tries for up to 3 s, matching the C implementation. */
    .global wa_instance_lock
    .type wa_instance_lock, %function
wa_instance_lock:
    stp x29, x30, [sp, #-48]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x29, sp
    mov x19, x0

    mov x0, #AT_FDCWD
    mov x1, x19
    mov w2, #(O_CREAT | O_RDWR)   // 0x42
    movz w3, #8, lsl #16          // O_CLOEXEC = 0x80000
    orr w2, w2, w3
    mov x3, #PERM_600
    mov x8, #SYS_OPENAT
    svc #0
    cmp x0, #0
    b.lt .Lil_fail
    mov x20, x0             // fd

    mov x21, #0             // tries
.Lil_try:
    mov x0, x20
    mov x1, #(LOCK_EX | LOCK_NB)
    mov x8, #SYS_FLOCK
    svc #0
    cbz x0, .Lil_ok
    add x21, x21, #1
    cmp x21, #30
    b.hs .Lil_busy
    mov x0, #100
    bl wa_sleep_ms
    b .Lil_try

.Lil_busy:
    mov x0, x20
    mov x8, #SYS_CLOSE
    svc #0
.Lil_fail:
    mov x0, #-1
    b .Lil_out
.Lil_ok:
    mov x0, x20
.Lil_out:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
    .size wa_instance_lock, .-wa_instance_lock

/* void wa_instance_unlock(int fd) */
    .global wa_instance_unlock
    .type wa_instance_unlock, %function
wa_instance_unlock:
    tbnz w0, #31, .Liu_ret    // never close a negative fd
    mov x8, #SYS_CLOSE
    svc #0
.Liu_ret:
    ret
    .size wa_instance_unlock, .-wa_instance_unlock

/* ------------------------------------------------------------------------
 * Process helpers. Raw syscalls only; aarch64 has no fork/dup2/access/unlink
 * syscalls, so fork is clone(SIGCHLD), dup2 is dup3(.., 0), access is
 * faccessat(AT_FDCWD, ..) and unlink is unlinkat(AT_FDCWD, .., 0).
 * ------------------------------------------------------------------------ */
    .equ SYS_DUP3,         24
    .equ SYS_FACCESSAT,    48
    .equ SYS_UNLINKAT,     35
    .equ SYS_CHDIR,        49
    .equ SYS_EXIT_GROUP,   94
    .equ SYS_SETSID,       157
    .equ SYS_CLONE,        220
    .equ SYS_EXECVE,       221
    .equ SYS_WAIT4,        260
    .equ SIGCHLD,          17
    .equ EINTR,            4

    .data
    .align 3
/* char **wa_envp - set by _start, handed to every execve */
    .global wa_envp
wa_envp:            .quad 0

    .section .rodata
wa_str_devnull:     .asciz "/dev/null"
wa_str_root:        .asciz "/"

    .text

/* void wa_exit(int code) - exit_group, never returns */
    .global wa_exit
    .type wa_exit, %function
wa_exit:
    mov x8, #SYS_EXIT_GROUP
    svc #0
    b wa_exit
    .size wa_exit, .-wa_exit

/* int wa_fork(void) - clone(SIGCHLD): 0 in child, pid in parent, <0 error */
    .global wa_fork
    .type wa_fork, %function
wa_fork:
    mov x0, #SIGCHLD
    mov x1, #0
    mov x2, #0
    mov x3, #0
    mov x4, #0
    mov x8, #SYS_CLONE
    svc #0
    ret
    .size wa_fork, .-wa_fork

/* int wa_exists(const char *path) - 1 when faccessat(F_OK) succeeds */
    .global wa_exists
    .type wa_exists, %function
wa_exists:
    mov x1, x0
    mov x0, #AT_FDCWD
    mov x2, #0                // F_OK
    mov x3, #0
    mov x8, #SYS_FACCESSAT
    svc #0
    cmp x0, #0
    cset x0, eq
    ret
    .size wa_exists, .-wa_exists

/* int wa_unlink(const char *path) - 0 or -errno */
    .global wa_unlink
    .type wa_unlink, %function
wa_unlink:
    mov x1, x0
    mov x0, #AT_FDCWD
    mov x2, #0
    mov x8, #SYS_UNLINKAT
    svc #0
    ret
    .size wa_unlink, .-wa_unlink

/* int wa_spawn(const char *path, char *const argv[])
 * fork + execve(path, argv, wa_envp); the child exits 127 if exec fails.
 * Returns the raw wait status, or -1 if fork failed. */
    .global wa_spawn
    .type wa_spawn, %function
wa_spawn:
    stp x29, x30, [sp, #-64]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x29, sp
    mov x19, x0
    mov x20, x1
    bl wa_fork
    cmp x0, #0
    b.lt .Lsp_fail
    b.eq .Lsp_child
    mov x21, x0               // child pid
    str wzr, [sp, #48]        // wait status slot, clear of the saved regs
.Lsp_wait:
    mov x0, x21
    add x1, sp, #48
    mov x2, #0
    mov x3, #0
    mov x8, #SYS_WAIT4
    svc #0
    cmn x0, #EINTR
    b.eq .Lsp_wait
    cmp x0, #0
    b.lt .Lsp_fail
    ldr w0, [sp, #48]
    b .Lsp_out
.Lsp_child:
    mov x0, x19
    mov x1, x20
    adrp x2, wa_envp
    add x2, x2, :lo12:wa_envp
    ldr x2, [x2]
    mov x8, #SYS_EXECVE
    svc #0
    mov x0, #127
    b wa_exit
.Lsp_fail:
    mov x0, #-1
.Lsp_out:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret
    .size wa_spawn, .-wa_spawn

/* int wa_spawn_bg(const char *path, char *const argv[])
 * Same as wa_spawn but does not wait for the program: an intermediate child
 * forks the real one and exits at once, so nothing is left as a zombie.
 * Returns the intermediate child's wait status, or -1. */
    .global wa_spawn_bg
    .type wa_spawn_bg, %function
wa_spawn_bg:
    stp x29, x30, [sp, #-48]!
    stp x19, x20, [sp, #16]
    mov x29, sp
    mov x19, x0
    mov x20, x1
    bl wa_fork
    cmp x0, #0
    b.lt .Lsb_fail
    b.ne .Lsb_parent
    // intermediate child: start the program, never wait for it
    bl wa_fork
    cbnz x0, .Lsb_mid_exit    // pid or error: either way we are done
    mov x0, x19
    mov x1, x20
    adrp x2, wa_envp
    add x2, x2, :lo12:wa_envp
    ldr x2, [x2]
    mov x8, #SYS_EXECVE
    svc #0
    mov x0, #127
    b wa_exit
.Lsb_mid_exit:
    mov x0, #0
    b wa_exit
.Lsb_parent:
    mov x19, x0
    str wzr, [sp, #32]        // wait status slot, clear of the saved regs
.Lsb_wait:
    mov x0, x19
    add x1, sp, #32
    mov x2, #0
    mov x3, #0
    mov x8, #SYS_WAIT4
    svc #0
    cmn x0, #EINTR
    b.eq .Lsb_wait
    cmp x0, #0
    b.lt .Lsb_fail
    ldr w0, [sp, #32]
    b .Lsb_out
.Lsb_fail:
    mov x0, #-1
.Lsb_out:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
    .size wa_spawn_bg, .-wa_spawn_bg

/* int wa_daemonize(void)
 * daemon(0, 0) without libc: fork, parent exits 0, child calls setsid,
 * chdir("/") and points 0/1/2 at /dev/null. Returns 0 in the daemon, -1 if
 * fork failed (the caller keeps running in the foreground then). */
    .global wa_daemonize
    .type wa_daemonize, %function
wa_daemonize:
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]
    mov x29, sp
    bl wa_fork
    cmp x0, #0
    b.lt .Ldz_fail
    b.eq .Ldz_child
    mov x0, #0
    b wa_exit
.Ldz_child:
    mov x8, #SYS_SETSID
    svc #0
    adrp x0, wa_str_root
    add x0, x0, :lo12:wa_str_root
    mov x8, #SYS_CHDIR
    svc #0
    mov x0, #AT_FDCWD
    adrp x1, wa_str_devnull
    add x1, x1, :lo12:wa_str_devnull
    mov x2, #O_RDWR
    mov x3, #0
    mov x8, #SYS_OPENAT
    svc #0
    cmp x0, #0
    b.lt .Ldz_ok
    mov x19, x0
    mov x20, #0
.Ldz_dup:
    cmp x19, x20
    b.eq .Ldz_dup_next        // dup3 rejects old == new; already in place
    mov x0, x19
    mov x1, x20
    mov x2, #0
    mov x8, #SYS_DUP3
    svc #0
.Ldz_dup_next:
    add x20, x20, #1
    cmp x20, #3
    b.lt .Ldz_dup
    cmp x19, #2
    b.le .Ldz_ok
    mov x0, x19
    mov x8, #SYS_CLOSE
    svc #0
.Ldz_ok:
    mov x0, #0
    b .Ldz_out
.Ldz_fail:
    mov x0, #-1
.Ldz_out:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
    .size wa_daemonize, .-wa_daemonize

/* char *wa_proc_path(char *out, long pid, const char *leaf)
 * Builds "/proc/<pid>/<leaf>" with the put_* helpers. Returns out. */
    .section .rodata
wa_str_proc:        .asciz "/proc/"
wa_str_slash:       .asciz "/"
    .text
    .global wa_proc_path
    .type wa_proc_path, %function
wa_proc_path:
    stp x29, x30, [sp, #-48]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x29, sp
    mov x19, x0
    mov x20, x1
    mov x21, x2
    bl wa_put_start
    adrp x0, wa_str_proc
    add x0, x0, :lo12:wa_str_proc
    bl wa_put_str
    mov x0, x20
    bl wa_put_dec
    adrp x0, wa_str_slash
    add x0, x0, :lo12:wa_str_slash
    bl wa_put_str
    mov x0, x21
    bl wa_put_str
    mov x0, x19
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
    .size wa_proc_path, .-wa_proc_path
