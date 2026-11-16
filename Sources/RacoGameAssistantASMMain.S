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
str_playboost:  .asciz "RIPROG_PLAYBOOST 1"
path_service:   .asciz "/system/bin/service"
str_service_b:  .asciz "service"
str_call:       .asciz "call"
str_sf:         .asciz "SurfaceFlinger"
str_1015:       .asciz "1015"
str_1022:       .asciz "1022"
str_i32:        .asciz "i32"
str_f:          .asciz "f"
str_one:        .asciz "1"

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
/* Per-game colour, the same two calls the C daemon makes through sh. The
 * R/G/B/S slots point into wa_rgb, filled by wa_split_rgb from the file. */
argv_sf_color:  .quad str_service_b, str_call, str_sf, str_1015, str_i32, str_one
                .quad str_f, wa_rgb + 0,  str_f, str_zero, str_f, str_zero, str_f, str_zero, str_f, str_zero
                .quad str_f, wa_rgb + 24, str_f, str_zero, str_f, str_zero, str_f, str_zero, str_f, str_zero
                .quad str_f, wa_rgb + 48, str_f, str_zero, str_f, str_zero, str_f, str_zero, str_f, str_zero
                .quad str_f, str_one, 0
argv_sf_sat:    .quad str_service_b, str_call, str_sf, str_1022, str_f, wa_rgb + 72, 0

    .bss
    .align 4
wa_path:        .skip 384
wa_mode:        .skip 256
wa_mode_str:    .skip 32
wa_rgb:         .skip 96
wa_raco:        .skip 4096
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

/* int wa_raco_has(const char *key) - a raco.txt line starts with key */
    .global wa_raco_has
    .type wa_raco_has, %function
wa_raco_has:
    stp x29, x30, [sp, #-32]!
    str x19, [sp, #16]
    mov x29, sp
    mov x19, x0
    adrp x0, path_racotxt
    add x0, x0, :lo12:path_racotxt
    adrp x1, wa_raco
    add x1, x1, :lo12:wa_raco
    mov x2, #4095
    bl wa_read_file
    cmp x0, #0
    b.lt .Lrh_no
    adrp x0, wa_raco
    add x0, x0, :lo12:wa_raco
    mov x1, x19
    bl wa_line_starts
    b .Lrh_out
.Lrh_no:
    mov x0, #0
.Lrh_out:
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
    .size wa_raco_has, .-wa_raco_has

/* int wa_is_companion(void) */
    .global wa_is_companion
    .type wa_is_companion, %function
wa_is_companion:
    adrp x0, str_companion
    add x0, x0, :lo12:str_companion
    b wa_raco_has
    .size wa_is_companion, .-wa_is_companion

/* int wa_touch(const char *path) - create if missing, 0 or -1 */
    .global wa_touch
    .type wa_touch, %function
wa_touch:
    mov x1, x0
    mov x0, #-100             // AT_FDCWD
    mov w2, #0x41             // O_CREAT | O_WRONLY
    movz w3, #8, lsl #16      // O_CLOEXEC
    orr w2, w2, w3
    mov x3, #0644
    mov x8, #56               // openat
    svc #0
    cmp x0, #0
    b.lt .Lt_fail
    mov x8, #57               // close
    svc #0
    mov x0, #0
    ret
.Lt_fail:
    mov x0, #-1
    ret
    .size wa_touch, .-wa_touch

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
    mov x2, #255
    bl wa_read_file
    cmp x0, #0
    b.le .Lrl_have_mode
    adrp x0, wa_mode
    add x0, x0, :lo12:wa_mode
    bl wa_atoi              // stops at the first newline: line 1 only
    cmp x0, #0
    b.le .Lrl_rgb           // empty, garbage or negative: keep 4
    mov x20, x0

.Lrl_rgb:
    // Line 2 "R G B S": Ayunda colour for this game, in the background
    // like the C daemon's sh '&'.
    adrp x0, wa_mode
    add x0, x0, :lo12:wa_mode
    adrp x1, wa_rgb
    add x1, x1, :lo12:wa_rgb
    bl wa_split_rgb
    cbz w0, .Lrl_have_mode
    adrp x0, path_ayflag
    add x0, x0, :lo12:path_ayflag
    bl wa_touch
    adrp x0, path_service
    add x0, x0, :lo12:path_service
    adrp x1, argv_sf_color
    add x1, x1, :lo12:argv_sf_color
    adrp x2, argv_sf_sat
    add x2, x2, :lo12:argv_sf_sat
    bl wa_spawn_bg2
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

    // RiProg PlayBoost: open every thread of the game to all CPUs. Done
    // after load, as in the C daemon, so the mode cannot undo it.
    adrp x0, str_playboost
    add x0, x0, :lo12:str_playboost
    bl wa_raco_has
    cbz w0, .Lrl_overlay
    adrp x0, wa_active_pid
    add x0, x0, :lo12:wa_active_pid
    ldr w0, [x0]
    cbz w0, .Lrl_overlay
    bl wa_playboost

.Lrl_overlay:
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

/* int wa_find_fg(const char *want)
 * Walks /dev/cpuset/top-app/cgroup.procs for a foreground process
 * (oom_score_adj <= 300, readable) whose package, cmdline cut at ':', is
 * want - or, when want is NULL, any package in the gamelist. Returns the pid
 * and leaves the package in wa_cmdline, or 0 when nothing matches. */
    .global wa_find_fg
    .type wa_find_fg, %function
wa_find_fg:
    stp x29, x30, [sp, #-48]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x29, sp
    mov x19, x0               // want

    adrp x0, path_procs
    add x0, x0, :lo12:path_procs
    adrp x1, wa_buf
    add x1, x1, :lo12:wa_buf
    mov x2, #32767
    bl wa_read_file
    cmp x0, #0
    b.lt .Lff_none

    adrp x22, wa_buf
    add x22, x22, :lo12:wa_buf
    mov x21, #0

.Lff_loop:
    ldrb w0, [x22, x21]
    cbz w0, .Lff_none
    sub w0, w0, #48
    cmp w0, #9
    b.hi .Lff_next

    add x0, x22, x21
    bl wa_atoi
    mov x20, x0
.Lff_skip_digits:
    ldrb w0, [x22, x21]
    sub w0, w0, #48
    cmp w0, #9
    b.hi .Lff_have_pid        // NUL lands here too
    add x21, x21, #1
    b .Lff_skip_digits

.Lff_have_pid:
    cmp x20, #0
    b.le .Lff_next

    mov w0, w20
    bl wa_pid_score
    mov x1, #-9999            // unreadable is never foreground
    cmp x0, x1
    b.eq .Lff_next
    cmp x0, #300
    b.gt .Lff_next

    mov w0, w20
    adrp x1, wa_cmdline
    add x1, x1, :lo12:wa_cmdline
    mov x2, #255
    bl wa_pid_cmdline
    cmp x0, #0
    b.le .Lff_next
    adrp x0, wa_cmdline
    add x0, x0, :lo12:wa_cmdline
    ldrb w1, [x0]
    cbz w1, .Lff_next
    bl wa_strip_colon

    adrp x0, wa_cmdline
    add x0, x0, :lo12:wa_cmdline
    cbz x19, .Lff_list
    mov x1, x19
    bl wa_strcmp_eq
    b .Lff_match
.Lff_list:
    bl wa_gamelist_has
.Lff_match:
    cbz w0, .Lff_next
    mov x0, x20
    b .Lff_out

.Lff_next:
    // the digit skip may already sit on the NUL; never step past it
    ldrb w0, [x22, x21]
    cbz w0, .Lff_none
    add x21, x21, #1
    b .Lff_loop

.Lff_none:
    mov x0, #0
.Lff_out:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret
    .size wa_find_fg, .-wa_find_fg

/* int wa_main(void) */
    .global wa_main
    .type wa_main, %function
wa_main:
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]
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
    bl wa_reap_all          // anything a timed-out wait left behind

    adrp x0, path_gamelist
    add x0, x0, :lo12:path_gamelist
    bl wa_gamelist_reload   // -1/-2 keep the cached list

    ldr w0, [x20]
    cbz w0, .Lm_scan

    bl wa_pid_score
    mov x1, #-9999
    cmp x0, x1
    b.eq .Lm_handover
    cmp x0, #300
    b.le .Lm_loop

.Lm_handover:
    // The tracked process went to the background or died. If another
    // process of the same game is in front now, follow it and keep the mode.
    adrp x0, wa_active_pkg
    add x0, x0, :lo12:wa_active_pkg
    bl wa_find_fg
    cbz w0, .Lm_unload
    str w0, [x20]
    b .Lm_loop

.Lm_unload:
    adrp x0, wa_active_pkg
    add x0, x0, :lo12:wa_active_pkg
    bl wa_run_unload
    str wzr, [x20]
    b .Lm_loop

.Lm_scan:
    mov x0, #0
    bl wa_find_fg
    cbz w0, .Lm_loop
    str w0, [x20]
    adrp x0, wa_active_pkg
    add x0, x0, :lo12:wa_active_pkg
    adrp x1, wa_cmdline
    add x1, x1, :lo12:wa_cmdline
    bl wa_strcpy
    adrp x0, wa_active_pkg
    add x0, x0, :lo12:wa_active_pkg
    bl wa_run_load
    b .Lm_loop

.Lm_exit:
    mov x0, #0
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
    .size wa_main, .-wa_main
