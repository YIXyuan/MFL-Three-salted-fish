#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

#include "report.h"

static int tcp_connect(const mfl_report_cfg *cfg)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct timeval tv;
    tv.tv_sec  = cfg->timeout_ms / 1000;
    tv.tv_usec = (cfg->timeout_ms % 1000) * 1000;
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)cfg->port);
    if (inet_pton(AF_INET, cfg->host, &a.sin_addr) != 1) {
        close(fd);
        return -2;
    }
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) {
        close(fd);
        return -3;
    }
    return fd;
}

static int write_all(int fd, const char *buf, size_t len)
{
    size_t off = 0;
    while (off < len) {
        ssize_t w = write(fd, buf + off, len - off);
        if (w < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        off += (size_t)w;
    }
    return 0;
}

static int resp_is_200(const char *resp, ssize_t r)
{
    if (r < 12) return 0;
    return (strncmp(resp, "HTTP/1.1 200", 12) == 0 ||
            strncmp(resp, "HTTP/1.0 200", 12) == 0);
}

int mfl_report_detection(const mfl_report_cfg *cfg,
                         const char *point_id, int severity)
{
    for (int attempt = 0; attempt <= MFL_REPORT_RETRIES; attempt++) {
        if (attempt) sleep(MFL_REPORT_RETRY_S);

        int fd = tcp_connect(cfg);
        if (fd < 0) continue;

        char body[128], req[512];
        int n = snprintf(body, sizeof(body),
                         "{\"items\":[{\"point_id\":\"%s\",\"severity\":%d}]}",
                         point_id, severity);
        if (n < 0 || (size_t)n >= sizeof(body)) { close(fd); continue; }
        int m = snprintf(req, sizeof(req),
                         "POST /api/detections HTTP/1.1\r\n"
                         "Host: %s:%d\r\n"
                         "Content-Type: application/json\r\n"
                         "Content-Length: %d\r\n"
                         "Connection: close\r\n\r\n%s",
                         cfg->host, cfg->port, n, body);
        if (m < 0 || (size_t)m >= sizeof(req)) { close(fd); continue; }

        if (write_all(fd, req, (size_t)m) != 0) { close(fd); continue; }
        char resp[256];
        ssize_t r = read(fd, resp, sizeof(resp) - 1);
        close(fd);
        if (r > 0) resp[r] = '\0';
        if (resp_is_200(resp, r)) return 0;
    }

    if (cfg->fail_csv[0])
        mfl_report_fail_csv_append(cfg->fail_csv, point_id, severity);
    return -1;
}

static int health_once(const mfl_report_cfg *cfg)
{
    int fd = tcp_connect(cfg);
    if (fd < 0) return -1;

    char req[256];
    int m = snprintf(req, sizeof(req),
                     "GET /api/health HTTP/1.1\r\n"
                     "Host: %s:%d\r\n"
                     "Connection: close\r\n\r\n",
                     cfg->host, cfg->port);
    if (m < 0 || (size_t)m >= sizeof(req)) { close(fd); return -1; }

    if (write_all(fd, req, (size_t)m) != 0) { close(fd); return -1; }
    char resp[256];
    ssize_t r = read(fd, resp, sizeof(resp) - 1);
    close(fd);
    return resp_is_200(resp, r) ? 0 : -1;
}

int mfl_report_wait_health(const mfl_report_cfg *cfg,
                           int wait_seconds, int interval_ms)
{
    if (wait_seconds <= 0) return 0;
    if (interval_ms <= 0) interval_ms = 1000;

    for (int t = 0; t < wait_seconds * 1000; t += interval_ms) {
        if (health_once(cfg) == 0) {
            fprintf(stderr, "[report] 后端就绪(%s:%d)\n", cfg->host, cfg->port);
            return 0;
        }
        usleep((useconds_t)interval_ms * 1000);
    }
    fprintf(stderr, "[report] health 等待超时(%ds), 继续运行(失败走兜底)\n",
            wait_seconds);
    return -1;
}

int mfl_report_fail_csv_append(const char *path,
                               const char *point_id, int severity)
{
    FILE *f = fopen(path, "a");
    if (!f) {
        fprintf(stderr, "[report] 兜底 CSV 打不开: %s (%s)\n",
                path, strerror(errno));
        return -1;
    }

    fseek(f, 0, SEEK_END);
    if (ftell(f) == 0)
        fprintf(f, "point_id,severity,timestamp_ms\n");

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    long long ms = (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
    fprintf(f, "%s,%d,%lld\n", point_id, severity, ms);
    fclose(f);
    return 0;
}
