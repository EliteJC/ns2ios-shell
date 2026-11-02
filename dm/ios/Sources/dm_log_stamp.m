// Timing aid for the shell build. A background thread follows this run's Documents/log.txt and writes a copy with a time in front of every
// line, Documents/log_timed.txt:
//     [+  12.345] [dm] ...
// The time is the seconds since the process was created (the same zero point as the [bootprof] and [longframe] times). A line is stamped when
// the thread notices it, within a few milliseconds of it being written. log.txt itself is not touched. The file is its own translation unit, so
// no other file has to change: dm/ios/project.yml compiles everything in Sources.
#ifdef DM_STAMP_TEST
#include "stamp_shim.h"
#else
#import <Foundation/Foundation.h>
#include <sys/sysctl.h>
#endif
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#ifndef DM_STAMP_TEST
// The Documents folder, as the app sees it (a launcher that redirects the data folder answers here too).
static int dm_stamp_doc_dir(char *out, size_t n) {
    @autoreleasepool {
        NSArray<NSString *> *a = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (!a.count) return -1;
        const char *p = a[0].fileSystemRepresentation;
        if (!p || strlen(p) >= n) return -1;
        strcpy(out, p);
        return 0;
    }
}

// When this process was created, as wall-clock time: the definition dm/host/main.c uses for its own boot timeline.
static int dm_stamp_proc_start(struct timeval *tv) {
    struct kinfo_proc kp; size_t n = sizeof kp; int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    if (sysctl(mib, 4, &kp, &n, NULL, 0) || !n) return -1;
    *tv = kp.kp_proc.p_starttime;
    return 0;
}
#endif

static double dm_stamp_since(const struct timespec *m0) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)(t.tv_sec - m0->tv_sec) + (double)(t.tv_nsec - m0->tv_nsec) / 1e9;
}

static void *dm_stamp_main(void *unused) {
    (void)unused;
    struct timeval ps, w0; struct timespec m0;
    if (dm_stamp_proc_start(&ps)) return NULL;
    gettimeofday(&w0, NULL); clock_gettime(CLOCK_MONOTONIC, &m0);
    double age0 = (double)(w0.tv_sec - ps.tv_sec) + (double)(w0.tv_usec - ps.tv_usec) / 1e6;
    if (age0 < 0) age0 = 0;

    // This run's log.txt: the app moves the previous run's log aside and creates a new one early in main(), so the file that matters is the first one
    // modified at or after the process was created (the old one is minutes older at least).
    char doc[1024], src[1100], dst[1100];
    int fd = -1;
    for (int i = 0; i < 30000 && fd < 0; i++) {            // 60 s at 2 ms
        if (!dm_stamp_doc_dir(doc, sizeof doc)) {
            snprintf(src, sizeof src, "%s/log.txt", doc);
            struct stat st;
            if (!stat(src, &st)) {
#ifdef __APPLE__
                time_t mt = st.st_mtimespec.tv_sec;
#else
                time_t mt = st.st_mtim.tv_sec;
#endif
                if (mt >= ps.tv_sec) fd = open(src, O_RDONLY);
            }
        }
        if (fd < 0) usleep(2000);
    }
    if (fd < 0) return NULL;
    snprintf(dst, sizeof dst, "%s/log_timed.txt", doc);
    FILE *out = fopen(dst, "w");
    if (!out) { close(fd); return NULL; }

    struct tm tmv; time_t sec = w0.tv_sec; localtime_r(&sec, &tmv);
    fprintf(out, "[+%8.3f] timed copy of log.txt; seconds since the process was created. Watching began at %02d:%02d:%02d.%03d local time.\n",
            age0, tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (int)(w0.tv_usec / 1000));
    fflush(out);

    static char buf[65536];
    size_t n = 0;
    for (;;) {
        ssize_t r = read(fd, buf + n, sizeof buf - n - 1);
        if (r > 0) {
            double s = age0 + dm_stamp_since(&m0);
            n += (size_t)r;
            char *p = buf, *nl;
            while ((nl = memchr(p, '\n', (size_t)(buf + n - p)))) {
                fprintf(out, "[+%8.3f] %.*s\n", s, (int)(nl - p), p);
                p = nl + 1;
            }
            n = (size_t)(buf + n - p);
            memmove(buf, p, n);
            if (n >= sizeof buf - 1) { fprintf(out, "[+%8.3f] %.*s\n", s, (int)n, buf); n = 0; }
            fflush(out);
            continue;
        }
        if (r < 0 && errno != EINTR) break;
        usleep(2000);
    }
    fclose(out); close(fd);
    return NULL;
}

__attribute__((constructor)) static void dm_log_stamp_init(void) {
    pthread_t th; pthread_attr_t at;
    pthread_attr_init(&at); pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    pthread_create(&th, &at, dm_stamp_main, NULL);
    pthread_attr_destroy(&at);
}
