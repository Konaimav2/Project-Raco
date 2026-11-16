/*
 * Tests for the assembly Game Assistant helpers. The test itself uses libc;
 * only the daemon binary has to be libc-free.
 * Build: clang -O2 gameassist_asm_test.c ../Sources/RacoGameAssistantASM.S -o gameassist_asm_test
 * Run:   WA_TEST_DIR=<writable dir> ./gameassist_asm_test
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/wait.h>
#include <sys/syscall.h>

extern long long wa_now_ms(void);
extern int wa_read_file(const char *path, char *buf, int cap);
extern int wa_gamelist_reload(const char *path);
extern int wa_gamelist_has(const char *pkg);
extern int wa_instance_lock(const char *path);
extern void wa_instance_unlock(int fd);
extern int wa_atoi(const char *s);
extern char *wa_strcpy(char *dst, const char *src);
extern char *wa_strstr(const char *hay, const char *needle);
extern void wa_put_start(char *buf);
extern void wa_put_str(const char *s);
extern void wa_put_dec(long v);
extern void wa_sleep_ms(long ms);
extern char **wa_envp;
extern char **environ;
extern int wa_fork(void);
extern int wa_exists(const char *path);
extern int wa_unlink(const char *path);
extern int wa_spawn(const char *path, char *const argv[]);
extern int wa_spawn_bg(const char *path, char *const argv[]);
extern int wa_daemonize(void);
extern char *wa_proc_path(char *out, long pid, const char *leaf);

static int pass = 0, fail = 0;

#define CHECK(cond) do { \
    if (cond) { pass++; } \
    else { fail++; printf("FAIL line %d: %s\n", __LINE__, #cond); } \
} while (0)

static void write_file(const char *path, const char *text) {
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(2); }
    fputs(text, f);
    fclose(f);
}

int main(void) {
    const char *dir = getenv("WA_TEST_DIR");
    if (!dir) dir = "/data/data/com.termux/files/home/temp/wa-tests";
    char path[512];
    char buf[64];

    // monotonic clock
    long long t0 = wa_now_ms();
    usleep(50000);
    long long t1 = wa_now_ms();
    CHECK(t1 >= t0);
    CHECK((t1 - t0) >= 40);

    // read_file
    snprintf(path, sizeof path, "%s/data.txt", dir);
    write_file(path, "hello");
    memset(buf, 0, sizeof buf);
    int n = wa_read_file(path, buf, sizeof buf);
    CHECK(n == 5);
    CHECK(strcmp(buf, "hello") == 0);
    CHECK(wa_read_file("/nonexistent/nope", buf, sizeof buf) == -1);

    // gamelist: exact whole-line matching
    snprintf(path, sizeof path, "%s/gamelist.txt", dir);
    write_file(path, "com.a\ncom.b\n");
    CHECK(wa_gamelist_reload(path) == 1);
    CHECK(wa_gamelist_has("com.a") == 1);
    CHECK(wa_gamelist_has("com.b") == 1);
    CHECK(wa_gamelist_has("com") == 0);
    CHECK(wa_gamelist_has("com.aa") == 0);
    CHECK(wa_gamelist_reload(path) == 0);   // unchanged

    // reload on change, CRLF tolerated
    write_file(path, "com.c\r\ncom.d\n");
    CHECK(wa_gamelist_reload(path) == 1);
    CHECK(wa_gamelist_has("com.c") == 1);
    CHECK(wa_gamelist_has("com.d") == 1);
    CHECK(wa_gamelist_has("com.a") == 0);

    // last line without newline
    write_file(path, "com.e");
    CHECK(wa_gamelist_reload(path) == 1);
    CHECK(wa_gamelist_has("com.e") == 1);
    CHECK(wa_gamelist_has("com.ee") == 0);

    // empty file matches nothing
    write_file(path, "");
    CHECK(wa_gamelist_reload(path) == 1);
    CHECK(wa_gamelist_has("com.e") == 0);

    // a package that is a prefix of a line, blank lines in between
    write_file(path, "\n\ncom.game.full\n\ncom.other\n");
    CHECK(wa_gamelist_reload(path) == 1);
    CHECK(wa_gamelist_has("com.game") == 0);
    CHECK(wa_gamelist_has("com.game.full") == 1);
    CHECK(wa_gamelist_has("com.other") == 1);
    CHECK(wa_gamelist_has("") == 0);

    // same size, different bytes still counts as a change
    write_file(path, "com.x1\n");
    CHECK(wa_gamelist_reload(path) == 1);
    write_file(path, "com.x2\n");
    CHECK(wa_gamelist_reload(path) == 1);
    CHECK(wa_gamelist_has("com.x2") == 1);
    CHECK(wa_gamelist_has("com.x1") == 0);

    // a missing list keeps the cached one
    CHECK(wa_gamelist_reload("/nonexistent/gamelist.txt") == -1);
    CHECK(wa_gamelist_has("com.x2") == 1);

    // atoi, matched against libc atoi on the inputs the daemon sees
    static const char *atoi_in[] = {
        "0", "456", "  -123", "x", "", "+7", "\n\t 42", "-1000\n", "300\n",
        "12abc", "4\n0 0 0 0\n", "2147483647", "-2147483648", "- 5", "\v\f\r9",
    };
    for (size_t i = 0; i < sizeof atoi_in / sizeof atoi_in[0]; i++) {
        if (wa_atoi(atoi_in[i]) != atoi(atoi_in[i])) {
            fail++;
            printf("FAIL atoi(\"%s\") = %d, libc %d\n", atoi_in[i],
                   wa_atoi(atoi_in[i]), atoi(atoi_in[i]));
        } else {
            pass++;
        }
    }

    char dst[32];
    wa_strcpy(dst, "abc");
    CHECK(strcmp(dst, "abc") == 0);
    CHECK(wa_strstr("hello world", "world") != NULL);
    CHECK(wa_strstr("hello", "xyz") == NULL);
    CHECK(wa_strstr("hello", "") != NULL);

    // command builder
    char out[64];
    wa_put_start(out);
    wa_put_str("/proc/");
    wa_put_dec(12345);
    wa_put_str("/oom");
    CHECK(strcmp(out, "/proc/12345/oom") == 0);

    wa_put_start(out);
    wa_put_dec(0);
    CHECK(strcmp(out, "0") == 0);

    wa_put_start(out);
    wa_put_dec(2000000);
    CHECK(strcmp(out, "2000000") == 0);

    wa_put_start(out);
    wa_put_dec(18446744073709551615UL);   // unsigned: the full 20 digits
    CHECK(strcmp(out, "18446744073709551615") == 0);

    wa_put_start(out);
    wa_put_str("");
    CHECK(out[0] == 0);
    wa_put_str("a");
    wa_put_dec(4);
    wa_put_str("b");
    CHECK(strcmp(out, "a4b") == 0);

    // path building used by the daemon
    char pbuf[256];
    CHECK(wa_proc_path(pbuf, 1, "cmdline") == pbuf);
    CHECK(strcmp(pbuf, "/proc/1/cmdline") == 0);
    wa_proc_path(pbuf, 4194304, "oom_score_adj");
    CHECK(strcmp(pbuf, "/proc/4194304/oom_score_adj") == 0);
    wa_put_start(pbuf);
    wa_put_str("/data/ProjectRaco/modes/");
    wa_put_str("com.example.game");
    CHECK(strcmp(pbuf, "/data/ProjectRaco/modes/com.example.game") == 0);

    // the oom_score_adj of a real pid reads back through the helpers
    char want[32];
    snprintf(want, sizeof want, "/proc/%d/oom_score_adj", (int)getpid());
    wa_proc_path(pbuf, getpid(), "oom_score_adj");
    CHECK(strcmp(pbuf, want) == 0);
    CHECK(wa_read_file(pbuf, buf, sizeof buf) > 0);

    // wa_now_ms agrees with CLOCK_MONOTONIC in milliseconds
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    long long libc_ms = (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
    long long asm_ms = wa_now_ms();
    CHECK(asm_ms >= libc_ms && asm_ms - libc_ms < 50);

    // sleep helper: measured with libc's clock so a bad wa_now_ms cannot hide it
    for (int i = 0; i < 3; i++) {
        long ms = i == 0 ? 30 : (i == 1 ? 120 : 1001);
        struct timespec a, b;
        clock_gettime(CLOCK_MONOTONIC, &a);
        wa_sleep_ms(ms);
        clock_gettime(CLOCK_MONOTONIC, &b);
        long long el = (b.tv_sec - a.tv_sec) * 1000LL + (b.tv_nsec - a.tv_nsec) / 1000000;
        CHECK(el >= ms);
        CHECK(el < ms + 150);
    }
    long long s0 = wa_now_ms();
    wa_sleep_ms(30);
    long long s1 = wa_now_ms();
    CHECK((s1 - s0) >= 20);

    // exists / unlink
    snprintf(path, sizeof path, "%s/flag", dir);
    write_file(path, "");
    CHECK(wa_exists(path) == 1);
    CHECK(wa_unlink(path) == 0);
    CHECK(wa_exists(path) == 0);
    CHECK(wa_unlink(path) < 0);

    // spawn: argv reaches the program, the status comes back, no shell needed
    wa_envp = environ;
    char *av1[] = {"sh", "-c", "[ \"$0\" = argx ] && [ \"$1\" = 'b c' ] && exit 5; exit 9", "argx", "b c", NULL};
    int st = wa_spawn("/system/bin/sh", av1);
    CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 5);
    char *av2[] = {"nope", NULL};
    st = wa_spawn("/nonexistent/binary", av2);
    CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 127);
    char *envp_test[] = {"WA_T=ok", NULL};
    wa_envp = envp_test;
    char *av3[] = {"sh", "-c", "[ \"$WA_T\" = ok ] && exit 0; exit 1", NULL};
    st = wa_spawn("/system/bin/sh", av3);
    CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0);
    wa_envp = environ;

    // spawn_bg returns before the program finishes and leaves no child behind
    snprintf(path, sizeof path, "%s/bg.done", dir);
    unlink(path);
    char bgcmd[600];
    snprintf(bgcmd, sizeof bgcmd, "sleep 0.4; echo > '%s'", path);
    char *av4[] = {"sh", "-c", bgcmd, NULL};
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    st = wa_spawn_bg("/system/bin/sh", av4);
    clock_gettime(CLOCK_MONOTONIC, &b);
    long long el = (b.tv_sec - a.tv_sec) * 1000LL + (b.tv_nsec - a.tv_nsec) / 1000000;
    CHECK(st == 0);
    CHECK(el < 300);
    CHECK(waitpid(-1, NULL, WNOHANG) == -1);   // nothing left to reap
    for (int i = 0; i < 20 && access(path, F_OK) != 0; i++) usleep(100000);
    CHECK(access(path, F_OK) == 0);

    // daemonize: new session, cwd "/", stdio on /dev/null, caller's child exits 0
    snprintf(path, sizeof path, "%s/daemon.out", dir);
    unlink(path);
    pid_t kid = fork();
    if (kid == 0) {
        wa_daemonize();
        char cwd[64] = "", fd0[64] = "", fd2[64] = "";
        getcwd(cwd, sizeof cwd);
        readlink("/proc/self/fd/0", fd0, sizeof fd0 - 1);
        readlink("/proc/self/fd/2", fd2, sizeof fd2 - 1);
        FILE *f = fopen(path, "w");
        if (f) {
            /* raw getpid: bionic caches the pid and a raw clone does not refresh it */
            fprintf(f, "%d %s %s %s", getsid(0) == (pid_t)syscall(SYS_getpid), cwd, fd0, fd2);
            fclose(f);
        }
        _exit(0);
    }
    int kst = -1;
    waitpid(kid, &kst, 0);
    CHECK(WIFEXITED(kst) && WEXITSTATUS(kst) == 0);
    char dout[256] = "";
    for (int i = 0; i < 20 && wa_read_file(path, dout, sizeof dout) <= 0; i++) usleep(50000);
    CHECK(strcmp(dout, "1 / /dev/null /dev/null") == 0);

    // single instance lock
    snprintf(path, sizeof path, "%s/inst.lock", dir);
    unlink(path);
    int fd1 = wa_instance_lock(path);
    CHECK(fd1 >= 0);
    clock_gettime(CLOCK_MONOTONIC, &a);
    int fd2 = wa_instance_lock(path);   // takes ~3 s to give up
    clock_gettime(CLOCK_MONOTONIC, &b);
    el = (b.tv_sec - a.tv_sec) * 1000LL + (b.tv_nsec - a.tv_nsec) / 1000000;
    CHECK(fd2 == -1);
    CHECK(el >= 2800 && el < 4000);
    CHECK(fcntl(fd1, F_GETFD) & FD_CLOEXEC);
    wa_instance_unlock(fd1);
    int fd3 = wa_instance_lock(path);
    CHECK(fd3 >= 0);
    wa_instance_unlock(fd3);
    wa_instance_unlock(-1);             // must not close anything
    CHECK(fcntl(0, F_GETFD) != -1);

    printf("PASS=%d FAIL=%d\n", pass, fail);
    return fail ? 1 : 0;
}
