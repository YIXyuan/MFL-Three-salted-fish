#ifndef MFL_REPORT_H
#define MFL_REPORT_H

#include <stddef.h>

#define MFL_REPORT_RETRIES   2
#define MFL_REPORT_RETRY_S   1

typedef struct {
    char host[32];
    int  port;
    int  timeout_ms;
    char fail_csv[512];
} mfl_report_cfg;

int mfl_report_detection(const mfl_report_cfg *cfg,
                         const char *point_id, int severity);

int mfl_report_wait_health(const mfl_report_cfg *cfg,
                           int wait_seconds, int interval_ms);

int mfl_report_fail_csv_append(const char *path,
                               const char *point_id, int severity);

#endif
