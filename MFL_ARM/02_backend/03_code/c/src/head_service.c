#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "head_service.h"
#include "quant_params.h"

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
typedef SOCKET sock_t;
#define SOCK_INVALID INVALID_SOCKET
#define sock_close closesocket
#else
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <errno.h>
typedef int sock_t;
#define SOCK_INVALID (-1)
#define sock_close close
#endif

static struct {
    mfl_service_cfg_t cfg;
    FILE       *csv;
    int         inited;
    int8_t      pool_buf[FEAT_C * FEAT_H * FEAT_W];
#ifdef _WIN32
    int         wsa_ready;
#endif
} g;

const char *mfl_class_label_en(int pred)
{
    static const char *n[] = { "normal", "light", "severe" };
    return (pred >= 0 && pred <= 2) ? n[pred] : "unknown";
}

const char *mfl_class_label_zh(int pred)
{
    static const char *n[] = { "无腐蚀", "轻度", "重度" };
    return (pred >= 0 && pred <= 2) ? n[pred] : "未知";
}

int mfl_point_id_from_name(const char *image_name, char *out, int out_size)
{
    if (!image_name || !out || out_size < 2) return -1;
    const char *base = image_name;
    for (const char *p = image_name; *p; p++)
        if (*p == '/' || *p == '\\') base = p + 1;

    int n = 0;
    while (base[n] && base[n] != '_' && base[n] != '.' && n < out_size - 1) {
        char c = base[n];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') || c == '-'))
            return -1;
        out[n] = c;
        n++;
    }
    out[n] = 0;
    return n > 0 ? 0 : -1;
}

static long long now_ms(void)
{
#ifdef _WIN32
    struct timespec ts;
    timespec_get(&ts, TIME_UTC);
#else
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
#endif
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int json_safe(const char *s)
{
    if (!s || !*s) return 0;
    for (const char *p = s; *p; p++) {
        char c = *p;
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') || c == '-' || c == '_'))
            return 0;
    }
    return 1;
}

static int image_safe(const char *s, char *out, size_t n)
{
    if (!s || !*s) return -1;
    const char *base = s;
    for (const char *p = s; *p; p++)
        if (*p == '/' || *p == '\\') base = p + 1;
    size_t len = strlen(base);
    if (len == 0 || len > 128 || len >= n) return -1;
    for (const char *p = base; *p; p++) {
        char c = *p;
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-'))
            return -1;
    }
    memcpy(out, base, len + 1);
    return 0;
}

#ifdef _WIN32
static int net_init(void)
{
    if (g.wsa_ready) return 0;
    WSADATA w;
    if (WSAStartup(MAKEWORD(2, 2), &w) != 0) return -1;
    g.wsa_ready = 1;
    return 0;
}
#else
static int net_init(void) { return 0; }
#endif

static int send_all(sock_t s, const char *buf, size_t len)
{
    size_t off = 0;
    while (off < len) {
#ifdef _WIN32
        int n = send(s, buf + off, (int)(len - off), 0);
#else
        ssize_t n = send(s, buf + off, len - off, 0);
#endif
        if (n <= 0) return -1;
        off += (size_t)n;
    }
    return 0;
}

static int http_post_json(const char *host, int port, const char *path,
                          const char *body, int timeout_ms, int *accepted)
{
    if (accepted) *accepted = -1;
    if (net_init() != 0) return -10;

    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, portstr, &hints, &res) != 0 || !res)
        return -11;

    int rc = -12;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        sock_t s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s == SOCK_INVALID) continue;

#ifdef _WIN32
        DWORD tv = (DWORD)(timeout_ms > 0 ? timeout_ms : 500);
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&tv, sizeof(tv));
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char *)&tv, sizeof(tv));
#else
        struct timeval tv;
        tv.tv_sec  = (timeout_ms > 0 ? timeout_ms : 500) / 1000;
        tv.tv_usec = ((timeout_ms > 0 ? timeout_ms : 500) % 1000) * 1000;
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
#endif
        if (connect(s, ai->ai_addr, (int)ai->ai_addrlen) != 0) {
            sock_close(s);
            continue;
        }

        char req[1024];
        int hlen = snprintf(req, sizeof(req),
            "POST %s HTTP/1.1\r\n"
            "Host: %s:%d\r\n"
            "Content-Type: application/json\r\n"
            "Content-Length: %d\r\n"
            "Connection: close\r\n"
            "\r\n",
            path, host, port, (int)strlen(body));
        if (hlen <= 0 || (size_t)hlen >= sizeof(req)) { sock_close(s); continue; }

        if (send_all(s, req, (size_t)hlen) != 0 ||
            send_all(s, body, strlen(body)) != 0) {
            sock_close(s);
            continue;
        }

        char resp[1024];
        size_t off = 0;
        for (;;) {
            if (off >= sizeof(resp) - 1) break;
#ifdef _WIN32
            int n = recv(s, resp + off, (int)(sizeof(resp) - 1 - off), 0);
#else
            ssize_t n = recv(s, resp + off, sizeof(resp) - 1 - off, 0);
#endif
            if (n <= 0) break;
            off += (size_t)n;
        }
        sock_close(s);
        if (off == 0) { rc = -13; continue; }
        resp[off] = 0;

        const char *ap = strstr(resp, "\"accepted\"");
        int acc = -1;
        if (ap) {
            ap = strchr(ap, ':');
            if (ap) acc = atoi(ap + 1);
        }
        if (accepted) *accepted = acc;

        if (strncmp(resp, "HTTP/", 5) == 0 && strstr(resp, " 200 ")) {
            rc = (acc == 0) ? -15 : 0;
        } else {
            rc = -14;
        }
        break;
    }
    freeaddrinfo(res);
    return rc;
}

int mfl_service_init(const mfl_service_cfg_t *cfg)
{
    if (!cfg || !cfg->weights_path) return -3;
    memset(&g, 0, sizeof(g));
    g.cfg = *cfg;
    if (g.cfg.timeout_ms <= 0) g.cfg.timeout_ms = 500;
    if (g.cfg.retries < 0)     g.cfg.retries = 0;

    int rc = mfl_head_load(cfg->weights_path);
    if (rc != 0) return -1;

    if (cfg->csv_path && *cfg->csv_path) {
        int fresh = 0;
        FILE *probe = fopen(cfg->csv_path, "rb");
        if (probe) {
            fseek(probe, 0, SEEK_END);
            fresh = (ftell(probe) == 0);
            fclose(probe);
        } else {
            fresh = 1;
        }
        g.csv = fopen(cfg->csv_path, "a");
        if (!g.csv) return -2;
        if (fresh)
            fprintf(g.csv, "ts_ms,image,point_id,pred,label,severity,conf,"
                           "logit0,logit1,logit2,prob0,prob1,prob2,post\n");
    } else {
        g.csv = NULL;
    }
    g.inited = 1;
    return 0;
}

void mfl_service_close(void)
{
    if (g.csv) { fflush(g.csv); fclose(g.csv); g.csv = NULL; }
    g.inited = 0;
#ifdef _WIN32
    if (g.wsa_ready) { WSACleanup(); g.wsa_ready = 0; }
#endif
}

static int service_run(const int8_t *feat, const char *point_id,
                       const char *image_name, mfl_service_result_t *out)
{
    if (!g.inited) return -1;
    if (!feat || !out) return -2;

    memset(out, 0, sizeof(*out));
    mfl_head_run(feat, &out->head);
    out->severity = out->head.pred;
    out->label = mfl_class_label_en(out->head.pred);
    out->ts_ms = now_ms();

    out->post_status = MFL_POST_DISABLED;
    if (g.cfg.server_host && *g.cfg.server_host && g.cfg.server_port > 0) {
        if (!point_id || !json_safe(point_id)) {
            out->post_status = -20;
        } else {
            char body[640];
            char img[136];
            int has_img = image_name && image_safe(image_name, img, sizeof(img)) == 0;
            int n = snprintf(body, sizeof(body),
                             "{\"items\":[{\"point_id\":\"%s\",\"severity\":%d",
                             point_id, out->severity);

            if (out->ts_ms >= 1600000000000LL && n > 0 && n < (int)sizeof(body))
                n += snprintf(body + n, sizeof(body) - (size_t)n,
                              ",\"timestamp\":%lld", out->ts_ms);

            if (n > 0 && n < (int)sizeof(body))
                n += snprintf(body + n, sizeof(body) - (size_t)n,
                              ",\"conf\":%.6f,\"probs\":[%.6f,%.6f,%.6f],"
                              "\"logits\":[%.6f,%.6f,%.6f]",
                              out->head.conf,
                              out->head.probs[0], out->head.probs[1], out->head.probs[2],
                              out->head.logits[0], out->head.logits[1], out->head.logits[2]);
            if (has_img && n > 0 && n < (int)sizeof(body))
                n += snprintf(body + n, sizeof(body) - (size_t)n,
                              ",\"image\":\"%s\"", img);
            if (n > 0 && n < (int)sizeof(body))
                snprintf(body + n, sizeof(body) - (size_t)n, "}]}");
            else
                body[0] = 0;

            out->post_status = -1;
            for (int attempt = 0; attempt <= g.cfg.retries; attempt++) {
                int acc = -1;
                int pr = http_post_json(g.cfg.server_host, g.cfg.server_port,
                                        "/api/detections", body, g.cfg.timeout_ms, &acc);
                if (pr == 0) { out->post_status = MFL_POST_OK; break; }
                out->post_status = pr;
            }
        }
    }

    if (g.csv) {
        fprintf(g.csv,
                "%lld,%s,%s,%d,%s,%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%d\n",
                out->ts_ms,
                image_name ? image_name : "",
                point_id ? point_id : "",
                out->head.pred, out->label, out->severity, out->head.conf,
                out->head.logits[0], out->head.logits[1], out->head.logits[2],
                out->head.probs[0], out->head.probs[1], out->head.probs[2],
                out->post_status);
        fflush(g.csv);
    }
    return 0;
}

int mfl_service_run15(const int8_t *feat15, const char *point_id,
                      const char *image_name, mfl_service_result_t *out)
{
    return service_run(feat15, point_id, image_name, out);
}

int mfl_service_run30(const int8_t *feat30, const char *point_id,
                      const char *image_name, mfl_service_result_t *out)
{
    if (!g.inited) return -1;
    if (!feat30 || !out) return -2;
    mfl_head_pool2_int8(feat30, g.pool_buf);
    return service_run(g.pool_buf, point_id, image_name, out);
}
