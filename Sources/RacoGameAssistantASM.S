/*
 * Project Raco - Performance and Gaming Optimization Suite
 * Assembly rewrite of the Game Assistant core (stage 1 helpers).
 *
 * These routines replace the C equivalents in RacoGameAssistant.c without
 * touching that file. Exported for tests:
 *   long long wa_now_ms(void);
 *   int  wa_read_file(const char *path, char *buf, int cap);
 *   int  wa_gamelist_reload(const char *path);   // 1 changed, 0 same, -1 error,
 *                                                // -2 over 64 KiB (cache kept)
 *   int  wa_gamelist_has(const char *pkg);       // whole-line match
 *   int  wa_instance_lock(const char *path);     // fd or -1
 *   void wa_instance_unlock(int fd);
 *   long wa_pid_score(int pid);                  // oom_score_adj or -9999
 *   int  wa_spawn_timeout(path, argv, max_ms);   // status, -2 killed, -1
 *   int  wa_spawn_bg2(path, argv1, argv2);       // "a ; b &"
 *   int  wa_split_rgb(text, out[4][24]);         // Ayunda line 2
 *   int  wa_playboost(int pid);                  // threads set to CPUs 0-7
 * Further helpers are documented where they are defined.
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
    .equ GAMELIST_MAX,     65536    // a bigger list is refused, never cut

    .bss
    .align 4
wa_tmp:             .skip GAMELIST_MAX + 16
gamelist:           .skip GAMELIST_MAX + 16
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
 * Reads the list into a temp buffer, swaps it in only when it changed.
 * 1 changed, 0 same, -1 unreadable, -2 larger than GAMELIST_MAX bytes.
 * On -1 and -2 the cached list stays as it was: a list that does not fit is
 * never matched partially. */
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
    add x2, x2, #2            // room to see one byte past the limit
    bl wa_read_file
    cmp x0, #0
    b.lt .Lgr_err
    mov x19, x0             // new len
    mov x1, #GAMELIST_MAX
    cmp x19, x1
    b.gt .Lgr_toobig

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

.Lgr_toobig:
    mov x0, #-2
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

/* int wa_wait_bounded(int pid, long max_ms)
 * Polls wait4(pid, WNOHANG) every 50 ms for up to max_ms. A child still
 * running after that gets SIGKILL and is reaped (up to 1 s more; anything
 * slower is left to wa_reap_all on the next tick).
 * Returns the wait status, -2 when it had to kill, -1 when wait4 failed. */
    .equ WNOHANG,          1
    .equ SYS_KILL,         129
    .equ SIGKILL,          9
    .global wa_wait_bounded
    .type wa_wait_bounded, %function
wa_wait_bounded:
    stp x29, x30, [sp, #-48]!
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x29, sp
    sxtw x19, w0
    mov x20, x1               // ms left
    str wzr, [sp, #40]        // wait status slot
.Lwb_poll:
    mov x0, x19
    add x1, sp, #40
    mov x2, #WNOHANG
    mov x3, #0
    mov x8, #SYS_WAIT4
    svc #0
    cmn x0, #EINTR
    b.eq .Lwb_poll
    cmp x0, #0
    b.lt .Lwb_err
    b.gt .Lwb_done
    cmp x20, #0
    b.le .Lwb_kill
    mov x0, #50
    bl wa_sleep_ms
    sub x20, x20, #50
    b .Lwb_poll
.Lwb_kill:
    mov x0, x19
    mov x1, #SIGKILL
    mov x8, #SYS_KILL
    svc #0
    mov x21, #20
.Lwb_reap:
    mov x0, x19
    add x1, sp, #40
    mov x2, #WNOHANG
    mov x3, #0
    mov x8, #SYS_WAIT4
    svc #0
    cmn x0, #EINTR
    b.eq .Lwb_reap
    cbnz x0, .Lwb_timeout     // reaped, or already gone
    subs x21, x21, #1
    b.eq .Lwb_timeout
    mov x0, #50
    bl wa_sleep_ms
    b .Lwb_reap
.Lwb_timeout:
    mov x0, #-2
    b .Lwb_out
.Lwb_done:
    ldr w0, [sp, #40]
    b .Lwb_out
.Lwb_err:
    mov x0, #-1
.Lwb_out:
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
    .size wa_wait_bounded, .-wa_wait_bounded

/* void wa_reap_all(void) - collect any exited child without blocking */
    .global wa_reap_all
    .type wa_reap_all, %function
wa_reap_all:
    mov x0, #-1
    mov x1, #0
    mov x2, #WNOHANG
    mov x3, #0
    mov x8, #SYS_WAIT4
    svc #0
    cmn x0, #EINTR
    b.eq wa_reap_all
    cmp x0, #0
    b.gt wa_reap_all
    ret
    .size wa_reap_all, .-wa_reap_all

/* int wa_spawn_timeout(const char *path, char *const argv[], long max_ms)
 * fork + execve(path, argv, wa_envp); the child exits 127 if exec fails.
 * Waits at most max_ms (see wa_wait_bounded). Returns the raw wait status,
 * -2 if the program was killed for running too long, -1 on fork failure. */
    .global wa_spawn_timeout
    .type wa_spawn_timeout, %function
wa_spawn_timeout:
    stp x29, x30, [sp, #-48]!
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x29, sp
    mov x19, x0
    mov x20, x1
    mov x21, x2
    bl wa_fork
    cmp x0, #0
    b.lt .Lst_fail
    b.eq .Lst_child
    mov x1, x21
    bl wa_wait_bounded
    b .Lst_out
.Lst_child:
    mov x0, x19
    mov x1, x20
    adrp x2, wa_envp
    add x2, x2, :lo12:wa_envp
    ldr x2, [x2]
    mov x8, #SYS_EXECVE
    svc #0
    mov x0, #127
    b wa_exit
.Lst_fail:
    mov x0, #-1
.Lst_out:
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
    .size wa_spawn_timeout, .-wa_spawn_timeout

/* int wa_spawn(const char *path, char *const argv[]) - 3 s limit */
    .global wa_spawn
    .type wa_spawn, %function
wa_spawn:
    mov x2, #3000
    b wa_spawn_timeout
    .size wa_spawn, .-wa_spawn

/* int wa_spawn_bg2(const char *path, char *const argv1[], char *const argv2[])
 * Runs path with argv1 and then (when argv2 is not NULL) path with argv2, in
 * the background like "a ; b &" in sh: an intermediate child forks the
 * worker and exits at once, so nothing is left as a zombie and the caller
 * does not wait for the programs. The worker gives argv1 the usual 3 s limit.
 * Returns the intermediate child's wait status, or -1. */
    .global wa_spawn_bg2
    .type wa_spawn_bg2, %function
wa_spawn_bg2:
    stp x29, x30, [sp, #-48]!
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x29, sp
    mov x19, x0
    mov x20, x1
    mov x21, x2
    bl wa_fork
    cmp x0, #0
    b.lt .Lsb_fail
    b.ne .Lsb_parent
    // intermediate child: start the worker, never wait for it
    bl wa_fork
    cbnz x0, .Lsb_mid_exit    // pid or error: either way we are done
    cbz x21, .Lsb_last
    mov x0, x19
    mov x1, x20
    bl wa_spawn
    mov x20, x21
.Lsb_last:
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
    mov x1, #3000
    bl wa_wait_bounded
    b .Lsb_out
.Lsb_fail:
    mov x0, #-1
.Lsb_out:
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
    .size wa_spawn_bg2, .-wa_spawn_bg2

/* int wa_spawn_bg(const char *path, char *const argv[]) */
    .global wa_spawn_bg
    .type wa_spawn_bg, %function
wa_spawn_bg:
    mov x2, #0
    b wa_spawn_bg2
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

/* ------------------------------------------------------------------------
 * oom_score_adj. -1 is a legal score, so errors come back as WA_NO_SCORE
 * (-9999), the same sentinel RacoGameAssistant.c uses.
 * ------------------------------------------------------------------------ */
    .equ WA_NO_SCORE,      -9999

    .bss
    .align 3
wa_sc_path:         .skip 64
wa_sc_buf:          .skip 32
wa_pb_path:         .skip 64
    .align 3
wa_dents:           .skip 4096

    .section .rodata
wa_str_score:       .asciz "oom_score_adj"
wa_str_task:        .asciz "task"
    .text

/* long wa_score_parse(const char *s)
 * The number at the start of s (after blanks), or -9999 when there is none. */
    .global wa_score_parse
    .type wa_score_parse, %function
wa_score_parse:
    mov x1, x0
.Lsp2_ws:
    ldrb w2, [x1]
    cmp w2, #32
    b.eq .Lsp2_adv
    sub w3, w2, #9
    cmp w3, #4
    b.hi .Lsp2_sign
.Lsp2_adv:
    add x1, x1, #1
    b .Lsp2_ws
.Lsp2_sign:
    cmp w2, #45               // '-'
    b.eq .Lsp2_signed
    cmp w2, #43               // '+'
    b.ne .Lsp2_digit
.Lsp2_signed:
    ldrb w2, [x1, #1]
.Lsp2_digit:
    sub w3, w2, #48
    cmp w3, #9
    b.hi .Lsp2_none
    b wa_atoi                 // x0 still points at the text
.Lsp2_none:
    mov x0, #WA_NO_SCORE
    ret
    .size wa_score_parse, .-wa_score_parse

/* long wa_pid_score(int pid) -> oom_score_adj, or -9999 if unreadable */
    .global wa_pid_score
    .type wa_pid_score, %function
wa_pid_score:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sxtw x1, w0
    adrp x0, wa_sc_path
    add x0, x0, :lo12:wa_sc_path
    adrp x2, wa_str_score
    add x2, x2, :lo12:wa_str_score
    bl wa_proc_path
    adrp x1, wa_sc_buf
    add x1, x1, :lo12:wa_sc_buf
    mov x2, #31
    bl wa_read_file
    cmp x0, #0
    b.le .Lpsc_err
    adrp x0, wa_sc_buf
    add x0, x0, :lo12:wa_sc_buf
    bl wa_score_parse
    b .Lpsc_out
.Lpsc_err:
    mov x0, #WA_NO_SCORE
.Lpsc_out:
    ldp x29, x30, [sp], #16
    ret
    .size wa_pid_score, .-wa_pid_score

/* int wa_strcmp_eq(const char *a, const char *b) - 1 when equal */
    .global wa_strcmp_eq
    .type wa_strcmp_eq, %function
wa_strcmp_eq:
    ldrb w2, [x0], #1
    ldrb w3, [x1], #1
    cmp w2, w3
    b.ne .Lse_no
    cbnz w2, wa_strcmp_eq
    mov x0, #1
    ret
.Lse_no:
    mov x0, #0
    ret
    .size wa_strcmp_eq, .-wa_strcmp_eq

/* int wa_line_starts(const char *text, const char *key)
 * 1 when some line of text begins with key, as strncmp(line, key, len) on
 * each fgets() line does in the C daemon. */
    .global wa_line_starts
    .type wa_line_starts, %function
wa_line_starts:
    mov x2, x0                // line start
.Lls_line:
    mov x3, x2
    mov x4, x1
.Lls_cmp:
    ldrb w5, [x4]
    cbz w5, .Lls_yes
    ldrb w6, [x3]
    cmp w5, w6
    b.ne .Lls_skip
    add x3, x3, #1
    add x4, x4, #1
    b .Lls_cmp
.Lls_skip:
    ldrb w6, [x2]
    cbz w6, .Lls_no
    add x2, x2, #1
    cmp w6, #10
    b.ne .Lls_skip
    b .Lls_line
.Lls_yes:
    mov x0, #1
    ret
.Lls_no:
    mov x0, #0
    ret
    .size wa_line_starts, .-wa_line_starts

/* int wa_split_rgb(const char *text, char out[4][24])
 * Line 2 of a modes/<pkg> file is "R G B S". Copies the first four tokens
 * into out as text, unchanged, and returns 1 when there are at least four
 * and each is a plain decimal ([+-]digits[.digits], at most 23 chars).
 * Returns 0 otherwise; out is then unspecified. */
    .global wa_split_rgb
    .type wa_split_rgb, %function
wa_split_rgb:
.Lsr_find:
    ldrb w2, [x0], #1
    cbz w2, .Lsr_no
    cmp w2, #10
    b.ne .Lsr_find
    mov x3, #0                // tokens done
.Lsr_ws:
    ldrb w2, [x0]
    cmp w2, #32
    b.eq .Lsr_adv
    cmp w2, #9
    b.eq .Lsr_adv
    cmp w2, #13
    b.eq .Lsr_adv
    cbz w2, .Lsr_no
    cmp w2, #10
    b.eq .Lsr_no
    mov x5, #24
    madd x4, x3, x5, x1       // out slot
    mov x6, #0                // length
    mov x7, #0                // digits
    mov x9, #0                // dots
.Lsr_tok:
    ldrb w2, [x0]
    cbz w2, .Lsr_end
    cmp w2, #32
    b.eq .Lsr_end
    cmp w2, #9
    b.eq .Lsr_end
    cmp w2, #13
    b.eq .Lsr_end
    cmp w2, #10
    b.eq .Lsr_end
    cmp x6, #23
    b.hs .Lsr_no
    sub w10, w2, #48
    cmp w10, #9
    b.hi .Lsr_notdig
    add x7, x7, #1
    b .Lsr_store
.Lsr_notdig:
    cmp w2, #46               // '.'
    b.ne .Lsr_sign
    add x9, x9, #1
    cmp x9, #1
    b.gt .Lsr_no
    b .Lsr_store
.Lsr_sign:
    cmp w2, #45               // '-'
    b.eq .Lsr_signok
    cmp w2, #43               // '+'
    b.ne .Lsr_no
.Lsr_signok:
    cbnz x6, .Lsr_no          // a sign only leads
.Lsr_store:
    strb w2, [x4, x6]
    add x6, x6, #1
    add x0, x0, #1
    b .Lsr_tok
.Lsr_end:
    cbz x7, .Lsr_no
    strb wzr, [x4, x6]
    add x3, x3, #1
    cmp x3, #4
    b.eq .Lsr_yes
    b .Lsr_ws
.Lsr_adv:
    add x0, x0, #1
    b .Lsr_ws
.Lsr_yes:
    mov x0, #1
    ret
.Lsr_no:
    mov x0, #0
    ret
    .size wa_split_rgb, .-wa_split_rgb

/* int wa_playboost(int pid)
 * Lets every thread of pid run on CPUs 0-7: walks /proc/<pid>/task with
 * getdents64 and calls sched_setaffinity(tid, 8, {0xff}) on each.
 * Returns how many threads took the mask, or -1 if the task dir is gone. */
    .equ SYS_GETDENTS64,   61
    .equ SYS_SCHED_SETAFFINITY, 122
    .equ O_DIRECTORY,      040000
    .equ WA_CPU_MASK,      0xff
    .global wa_playboost
    .type wa_playboost, %function
wa_playboost:
    stp x29, x30, [sp, #-80]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x29, sp
    sxtw x1, w0               // pid
    mov x2, #WA_CPU_MASK
    str x2, [sp, #64]         // cpu_set_t, 8 bytes
    mov x20, #0               // threads pinned

    adrp x0, wa_pb_path
    add x0, x0, :lo12:wa_pb_path
    adrp x2, wa_str_task
    add x2, x2, :lo12:wa_str_task
    bl wa_proc_path
    mov x1, x0
    mov x0, #AT_FDCWD
    mov w2, #O_DIRECTORY
    movz w3, #8, lsl #16      // O_CLOEXEC
    orr w2, w2, w3
    mov x3, #0
    mov x8, #SYS_OPENAT
    svc #0
    cmp x0, #0
    b.lt .Lpb_fail
    mov x19, x0               // dir fd

.Lpb_read:
    mov x0, x19
    adrp x1, wa_dents
    add x1, x1, :lo12:wa_dents
    mov x2, #4096
    mov x8, #SYS_GETDENTS64
    svc #0
    cmp x0, #0
    b.le .Lpb_done
    mov x21, x0               // bytes in this batch
    mov x22, #0               // offset
.Lpb_ent:
    cmp x22, x21
    b.hs .Lpb_read
    adrp x23, wa_dents
    add x23, x23, :lo12:wa_dents
    add x23, x23, x22         // struct linux_dirent64
    ldrh w24, [x23, #16]      // d_reclen
    cbz w24, .Lpb_done        // malformed, stop rather than spin
    ldrb w0, [x23, #19]       // d_name[0]
    sub w0, w0, #48
    cmp w0, #9
    b.hi .Lpb_next            // "." and ".."
    add x0, x23, #19
    bl wa_atoi
    cmp x0, #0
    b.le .Lpb_next
    mov x1, #8
    add x2, sp, #64
    mov x8, #SYS_SCHED_SETAFFINITY
    svc #0
    cbnz x0, .Lpb_next
    add x20, x20, #1
.Lpb_next:
    add x22, x22, x24
    b .Lpb_ent

.Lpb_done:
    mov x0, x19
    mov x8, #SYS_CLOSE
    svc #0
    mov x0, x20
    b .Lpb_out
.Lpb_fail:
    mov x0, #-1
.Lpb_out:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #80
    ret
    .size wa_playboost, .-wa_playboost
