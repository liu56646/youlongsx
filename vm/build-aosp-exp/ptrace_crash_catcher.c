/*
 * ptrace_crash_catcher.c — 在 QEMU 崩溃窗口期附加，拦截 SIGSEGV，
 * 转储故障线程寄存器 + 栈字 + maps 后放行（进程照常死亡）。
 *
 * 用法: ptrace_crash_catcher <qemu_pid> [seconds]
 * 行为: PTRACE_ATTACH 全部线程 -> 中转所有信号（保持行为不变）,
 *       遇到 SIGSEGV -> dump 到 /data/local/tmp/ptrace_crash.txt 后退出。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <time.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <sys/uio.h>
#include <sys/user.h>
#include <elf.h>
#include <sys/types.h>

static pid_t g_pid;
static int g_done = 0;

static void dump_regs(pid_t tid) {
    struct iovec iov;
    struct user_pt_regs regs;
    memset(&regs, 0, sizeof(regs));
    iov.iov_base = &regs;
    iov.iov_len = sizeof(regs);
    int fd = open("/data/local/tmp/ptrace_crash.txt",
                  O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (fd < 0) return;
    char b[512];
    int n = snprintf(b, sizeof b,
        "\n===== CRASH tid=%d =====\n", tid);
    write(fd, b, n);
    if (ptrace(PTRACE_GETREGSET, tid, (void*)NT_PRSTATUS, &iov) == 0) {
        unsigned long pc = regs.pc, sp = regs.sp, lr = regs.regs[30], fp = regs.regs[29];
        n = snprintf(b, sizeof b,
            "pc=0x%lx sp=0x%lx lr=0x%lx fp=0x%lx\n", pc, sp, lr, fp);
        write(fd, b, n);
        /* dump x0..x30 + pstate */
        for (int r = 0; r <= 30; r++) {
            n = snprintf(b, sizeof b, "x%d=0x%016lx%s", r, regs.regs[r],
                         (r % 2 == 1) ? "\n" : " ");
            write(fd, b, n);
        }
        n = snprintf(b, sizeof b, "\npstate=0x%lx\n", regs.pstate);
        write(fd, b, n);
        /* dump 64 words from SP */
        n = snprintf(b, sizeof b, "--- stack from sp ---\n");
        write(fd, b, n);
        for (int i = 0; i < 64; i++) {
            unsigned long v = 0;
            errno = 0;
            v = ptrace(PTRACE_PEEKDATA, tid, (void*)(sp + i * 8), NULL);
            if (errno) break;
            n = snprintf(b, sizeof b, "%03d 0x%016lx\n", i, v);
            write(fd, b, n);
        }
    } else {
        n = snprintf(b, sizeof b, "GETREGSET failed: %s\n", strerror(errno));
        write(fd, b, n);
    }
    /* maps */
    n = snprintf(b, sizeof b, "--- maps ---\n");
    write(fd, b, n);
    char mp[256];
    snprintf(mp, sizeof mp, "/proc/%d/maps", g_pid);
    int mf = open(mp, O_RDONLY);
    if (mf >= 0) {
        char buf[4096];
        ssize_t r;
        while ((r = read(mf, buf, sizeof buf)) > 0) write(fd, buf, (size_t)r);
        close(mf);
    }
    n = snprintf(b, sizeof b, "--- end ---\n");
    write(fd, b, n);
    close(fd);
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <pid> [seconds]\n", argv[0]); return 1; }
    g_pid = atoi(argv[1]);
    int secs = argc > 2 ? atoi(argv[2]) : 120;

    /* 附加所有线程 */
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/task", g_pid);
    DIR* d = opendir(path);
    if (!d) { perror("opendir"); return 1; }
    struct dirent* de;
    int nthreads = 0;
    while ((de = readdir(d))) {
        if (de->d_name[0] == '.') continue;
        pid_t tid = atoi(de->d_name);
        if (ptrace(PTRACE_ATTACH, tid, NULL, NULL) == 0) {
            int st;
            waitpid(tid, &st, __WALL);
            ptrace(PTRACE_SETOPTIONS, tid, NULL,
                   (void*)(PTRACE_O_TRACECLONE | PTRACE_O_TRACEFORK | PTRACE_O_TRACEVFORK));
            ptrace(PTRACE_CONT, tid, NULL, NULL);
            nthreads++;
        }
    }
    closedir(d);
    fprintf(stderr, "attached %d threads, pid %d\n", nthreads, g_pid);

    time_t start = time(NULL);
    while (!g_done && (time(NULL) - start) < secs) {
        int st = 0;
        pid_t tid = waitpid(-1, &st, __WALL);
        if (tid < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (WIFEXITED(st) || WIFSIGNALED(st)) {
            if (tid == g_pid) break;
            continue;
        }
        if (WIFSTOPPED(st)) {
            int sig = WSTOPSIG(st);
            if (sig == SIGSEGV || sig == SIGBUS || sig == SIGILL || sig == SIGFPE) {
                fprintf(stderr, "CATCH signal %d tid=%d\n", sig, tid);
                dump_regs(tid);
                g_done = 1;
                /* detach: 用 DETACH 传回信号 -> 目标走默认动作 */
                ptrace(PTRACE_DETACH, tid, NULL, (void*)(long)sig);
                break;
            }
            if (sig == SIGTRAP) {
                ptrace(PTRACE_CONT, tid, NULL, NULL);
                continue;
            }
            /* 其它信号：原样转发，保持目标行为 */
            ptrace(PTRACE_CONT, tid, NULL, (void*)(long)sig);
        }
    }

    if (!g_done) {
        fprintf(stderr, "timeout, detaching all\n");
    }
    /* 分离剩余线程 */
    DIR* d2 = opendir(path);
    if (d2) {
        while ((de = readdir(d2))) {
            if (de->d_name[0] == '.') continue;
            pid_t tid = atoi(de->d_name);
            ptrace(PTRACE_DETACH, tid, NULL, NULL);
        }
        closedir(d2);
    }
    return 0;
}
