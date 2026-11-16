/*
 * Project Raco - Game Assistant, assembly implementation (daemon loop).
 *
 * Freestanding: entered at _start, linked with -nostdlib -static, talks to the
 * kernel through raw syscalls only (helpers live in RacoGameAssistantASM.S).
 * Child programs are started with fork + execve and an argv array; no shell
 * is involved except for AyundaRusdi.sh, which is itself a shell script.
 *
 * Same external behaviour as RacoGameAssistant.c, minus inotify: a fixed
 * 500 ms tick is enough once the scan is cheap. RacoGameAssistant.c is not
 * modified.
 *
 * Detection: /dev/cpuset/top-app/cgroup.procs (processes), oom_score_adj <= 300,
 * cmdline matched whole-line against the cached gamelist.
 */

    .section .rodata
path_procs:     .asciz "/dev/cpuset/top-app/cgroup.procs"
path_gamelist:  .asciz "/data/ProjectRaco/gamelist.txt"
path_instance:  .asciz "/data/ProjectRaco/.gameassist.instance"
path_racotxt:   .asciz "/data/ProjectRaco/raco.txt"
path_modes:     .asciz "/data/ProjectRaco/modes/"
path_ayflag:    .asciz "/data/ProjectRaco/ayunda_active"
path_ayscript:  .asciz "/data/ProjectRaco/AyundaRusdi.sh"
path_linker:    .asciz "/system/bin/linker64"
path_raco:      .asciz "/data/adb/modules/ProjectRaco/Compiled/raco"
path_cmd:       .asciz "/system/bin/cmd"
path_am:        .asciz "/system/bin/am"
path_sh:        .asciz "/system/bin/sh"
leaf_score:     .asciz "oom_score_adj"
leaf_cmdline:   .asciz "cmdline"
str_load:       .asciz "load"
str_unload:     .asciz "unload"
str_zero:       .asciz "0"
str_cmd:        .asciz "cmd"
str_activity:   .asciz "activity"
str_startsvc:   .asciz "start-service"
str_user:       .asciz "--user"
str_current:    .asciz "current"
str_e:          .asciz "-e"
str_package:    .asciz "package"
str_service:    .asciz "com.kanagawa.yamada.project.raco/.GameAssistantService"
str_am:         .asciz "am"
str_forcestop:  .asciz "force-stop"
str_app:        .asciz "com.kanagawa.yamada.project.raco"
str_sh:         .asciz "sh"
str_companion:  .asciz "COMPANION_MODE 1"

/* argv arrays; the package slot (and the mode slot for load) is filled in
 * right before each spawn. */
    .data
    .align 3
argv_load:      .quad path_linker, path_raco, str_load
argv_load_pkg:  .quad 0
argv_load_mode: .quad wa_mode_str, 0
argv_unload:    .quad path_linker, path_raco, str_unload
argv_unload_pkg:.quad 0
                .quad str_zero, 0
argv_overlay:   .quad str_cmd, str_activity, str_startsvc, str_user, str_current
                .quad str_e, str_package
argv_overlay_pkg:.quad 0
                .quad str_service, 0
argv_stop:      .quad str_am, str_forcestop, str_app, 0
argv_ayunda:    .quad str_sh, path_ayscript, 0

    .bss
    .align 4
wa_path:        .skip 384
wa_mode:        .skip 64
wa_mode_str:    .skip 32
wa_small:       .skip 64
wa_raco:        .skip 512
wa_cmdline:     .skip 256
wa_buf:         .skip 32768
wa_active_pid:  .skip 4
wa_active_pkg:  .skip 256

    .text

/* void _start(void) - kernel entry. [sp] = argc, then argv[], NULL, envp[] */
    .global _start
    .type _start, %function
_start:
    mov x29, #0
    mov x30, #0
    ldr x0, [sp]              // argc
    add x1, sp, #8            // argv
    add x2, x1, x0, lsl #3
    add x2, x2, #8            // envp = argv + argc + 1
    adrp x3, wa_envp
    add x3, x3, :lo12:wa_envp
    str x2, [x3]
    bl wa_main
    b wa_exit
    .size _start, .-_start

/* long wa_pid_score(int pid) -> oom_score_adj, or -1 if unreadable */
    .global wa_pid_score
    .type wa_pid_score, %function
wa_pid_score:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sxtw x1, w0
    adrp x0, wa_path
    add x0, x0, :lo12:wa_path
    adrp x2, leaf_score
    add x2, x2, :lo12:leaf_score
    bl wa_proc_path

    adrp x1, wa_small
    add x1, x1, :lo12:wa_small
    mov x2, #63
    bl wa_read_file
    cmp x0, #0
    b.lt .Lps_err

    adrp x0, wa_small
    add x0, x0, :lo12:wa_small
    bl wa_atoi
    b .Lps_out
.Lps_err:
    mov x0, #-1
.Lps_out:
    ldp x29, x30, [sp], #16
    ret
    .size wa_pid_score, .-wa_pid_score

/* int wa_pid_cmdline(int pid, char *out, int cap) */
    .global wa_pid_cmdline
    .type wa_pid_cmdline, %function
wa_pid_cmdline:
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]
    mov x29, sp
    mov x19, x1
    mov w20, w2
    sxtw x1, w0
    adrp x0, wa_path
    add x0, x0, :lo12:wa_path
    adrp x2, leaf_cmdline
    add x2, x2, :lo12:leaf_cmdline
    bl wa_proc_path
    mov x1, x19
    mov w2, w20
    bl wa_read_file
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
    .size wa_pid_cmdline, .-wa_pid_cmdline

/* int wa_is_companion(void) */
    .global wa_is_companion
    .type wa_is_companion, %function
wa_is_companion:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x0, path_racotxt
    add x0, x0, :lo12:path_racotxt
    adrp x1, wa_raco
    add x1, x1, :lo12:wa_raco
    mov x2, #511
    bl wa_read_file
    cmp x0, #0
    b.lt .Lic_no
    adrp x0, wa_raco
    add x0, x0, :lo12:wa_raco
    adrp x1, str_companion
    add x1, x1, :lo12:str_companion
    bl wa_strstr
    cbnz x0, .Lic_yes
.Lic_no:
    mov x0, #0
    b .Lic_out
.Lic_yes:
    mov x0, #1
.Lic_out:
    ldp x29, x30, [sp], #16
    ret
    .size wa_is_companion, .-wa_is_companion

/* void wa_run_load(const char *pkg) */
    .global wa_run_load
    .type wa_run_load, %function
wa_run_load:
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]
    mov x29, sp
    mov x19, x0             // pkg
    mov x20, #4             // default mode

    // Companion mode keeps the default, as exec_performance() does.
    bl wa_is_companion
    cbnz w0, .Lrl_have_mode

    adrp x0, wa_path
    add x0, x0, :lo12:wa_path
    bl wa_put_start
    adrp x0, path_modes
    add x0, x0, :lo12:path_modes
    bl wa_put_str
    mov x0, x19
    bl wa_put_str

    adrp x0, wa_path
    add x0, x0, :lo12:wa_path
    adrp x1, wa_mode
    add x1, x1, :lo12:wa_mode
    mov x2, #63
    bl wa_read_file
    cmp x0, #0
    b.le .Lrl_have_mode
    adrp x0, wa_mode
    add x0, x0, :lo12:wa_mode
    bl wa_atoi              // stops at the first newline: line 1 only
    cmp x0, #0
    b.le .Lrl_have_mode     // empty, garbage or negative: keep 4
    mov x20, x0
.Lrl_have_mode:
    adrp x0, wa_mode_str
    add x0, x0, :lo12:wa_mode_str
    bl wa_put_start
    mov x0, x20
    bl wa_put_dec

    adrp x1, argv_load_pkg
    add x1, x1, :lo12:argv_load_pkg
    str x19, [x1]
    adrp x0, path_linker
    add x0, x0, :lo12:path_linker
    adrp x1, argv_load
    add x1, x1, :lo12:argv_load
    bl wa_spawn

    bl wa_is_companion
    cbnz w0, .Lrl_out

    adrp x1, argv_overlay_pkg
    add x1, x1, :lo12:argv_overlay_pkg
    str x19, [x1]
    adrp x0, path_cmd
    add x0, x0, :lo12:path_cmd
    adrp x1, argv_overlay
    add x1, x1, :lo12:argv_overlay
    bl wa_spawn
.Lrl_out:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
    .size wa_run_load, .-wa_run_load

/* void wa_run_unload(const char *pkg) */
    .global wa_run_unload
    .type wa_run_unload, %function
wa_run_unload:
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]
    mov x29, sp
    mov x19, x0

    bl wa_is_companion
    cbnz w0, .Lru_ayunda
    adrp x0, path_am
    add x0, x0, :lo12:path_am
    adrp x1, argv_stop
    add x1, x1, :lo12:argv_stop
    bl wa_spawn

.Lru_ayunda:
    // The C version backgrounds this with '&'; wa_spawn_bg keeps that.
    adrp x0, path_ayflag
    add x0, x0, :lo12:path_ayflag
    bl wa_exists
    cbz w0, .Lru_unload
    adrp x0, path_ayflag
    add x0, x0, :lo12:path_ayflag
    bl wa_unlink
    adrp x0, path_sh
    add x0, x0, :lo12:path_sh
    adrp x1, argv_ayunda
    add x1, x1, :lo12:argv_ayunda
    bl wa_spawn_bg

.Lru_unload:
    adrp x1, argv_unload_pkg
    add x1, x1, :lo12:argv_unload_pkg
    str x19, [x1]
    adrp x0, path_linker
    add x0, x0, :lo12:path_linker
    adrp x1, argv_unload
    add x1, x1, :lo12:argv_unload
    bl wa_spawn

    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
    .size wa_run_unload, .-wa_run_unload

/* void wa_strip_colon(char *s) - cut at the first ':' */
    .global wa_strip_colon
    .type wa_strip_colon, %function
wa_strip_colon:
.Lsc_loop:
    ldrb w1, [x0]
    cbz w1, .Lsc_ret
    cmp w1, #58
    b.eq .Lsc_cut
    add x0, x0, #1
    b .Lsc_loop
.Lsc_cut:
    strb wzr, [x0]
.Lsc_ret:
    ret
    .size wa_strip_colon, .-wa_strip_colon

/* int wa_main(void) */
    .global wa_main
    .type wa_main, %function
wa_main:
    stp x29, x30, [sp, #-64]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    mov x29, sp

    bl wa_daemonize

    adrp x0, path_instance
    add x0, x0, :lo12:path_instance
    bl wa_instance_lock
    cmp x0, #0
    b.lt .Lm_exit
    mov x19, x0             // lock fd, held for the life of the process

    adrp x20, wa_active_pid
    add x20, x20, :lo12:wa_active_pid

.Lm_loop:
    mov x0, #500
    bl wa_sleep_ms

    adrp x0, path_gamelist
    add x0, x0, :lo12:path_gamelist
    bl wa_gamelist_reload

    ldr w0, [x20]
    cbz w0, .Lm_scan

    bl wa_pid_score
    cmn x0, #1
    b.eq .Lm_unload
    cmp x0, #300
    b.le .Lm_loop

.Lm_unload:
    adrp x0, wa_active_pkg
    add x0, x0, :lo12:wa_active_pkg
    bl wa_run_unload
    str wzr, [x20]
    b .Lm_loop

.Lm_scan:
    adrp x0, path_procs
    add x0, x0, :lo12:path_procs
    adrp x1, wa_buf
    add x1, x1, :lo12:wa_buf
    mov x2, #32767
    bl wa_read_file
    cmp x0, #0
    b.lt .Lm_loop

    adrp x22, wa_buf
    add x22, x22, :lo12:wa_buf
    mov x21, #0

.Lm_scan_loop:
    ldrb w0, [x22, x21]
    cbz w0, .Lm_loop
    cmp w0, #48
    b.lt .Lm_scan_next
    cmp w0, #57
    b.gt .Lm_scan_next

    add x0, x22, x21
    bl wa_atoi
    mov x23, x0

.Lm_skip_digits:
    ldrb w0, [x22, x21]
    cbz w0, .Lm_have_pid
    cmp w0, #48
    b.lt .Lm_have_pid
    cmp w0, #57
    b.gt .Lm_have_pid
    add x21, x21, #1
    b .Lm_skip_digits

.Lm_have_pid:
    cmp x23, #0
    b.le .Lm_scan_next

    mov w0, w23
    bl wa_pid_score
    cmn x0, #1
    b.eq .Lm_scan_next
    cmp x0, #300
    b.gt .Lm_scan_next

    mov w0, w23
    adrp x1, wa_cmdline
    add x1, x1, :lo12:wa_cmdline
    mov x2, #255
    bl wa_pid_cmdline
    cmp x0, #0
    b.le .Lm_scan_next

    adrp x0, wa_cmdline
    add x0, x0, :lo12:wa_cmdline
    ldrb w1, [x0]
    cbz w1, .Lm_scan_next

    bl wa_strip_colon

    adrp x0, wa_cmdline
    add x0, x0, :lo12:wa_cmdline
    bl wa_gamelist_has
    cbz w0, .Lm_scan_next

    str w23, [x20]
    adrp x0, wa_active_pkg
    add x0, x0, :lo12:wa_active_pkg
    adrp x1, wa_cmdline
    add x1, x1, :lo12:wa_cmdline
    bl wa_strcpy
    adrp x0, wa_active_pkg
    add x0, x0, :lo12:wa_active_pkg
    bl wa_run_load
    b .Lm_loop

.Lm_scan_next:
    // wa_skip_digits may already sit on the NUL; never step past it
    ldrb w0, [x22, x21]
    cbz w0, .Lm_loop
    add x21, x21, #1
    b .Lm_scan_loop

.Lm_exit:
    mov x0, #0
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret
    .size wa_main, .-wa_main
