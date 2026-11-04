#ifndef MFL_HEAD_SERVICE_H
#define MFL_HEAD_SERVICE_H

#include <stdint.h>
#include "head.h"

#define MFL_CLASS_NORMAL 0
#define MFL_CLASS_LIGHT  1
#define MFL_CLASS_SEVERE 2

#define MFL_POST_OK       0
#define MFL_POST_DISABLED 1

typedef struct {
    const char *weights_path;
    const char *csv_path;
    const char *server_host;
    int         server_port;
    int         timeout_ms;
    int         retries;
} mfl_service_cfg_t;

typedef struct {
    mfl_head_result_t head;
    int         severity;
    const char *label;
    long long   ts_ms;
    int         post_status;
} mfl_service_result_t;

int  mfl_service_init(const mfl_service_cfg_t *cfg);

void mfl_service_close(void);

int mfl_service_run15(const int8_t *feat15, const char *point_id,
                      const char *image_name, mfl_service_result_t *out);

int mfl_service_run30(const int8_t *feat30, const char *point_id,
                      const char *image_name, mfl_service_result_t *out);

const char *mfl_class_label_en(int pred);
const char *mfl_class_label_zh(int pred);

int mfl_point_id_from_name(const char *image_name, char *out, int out_size);

#endif
