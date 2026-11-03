# MFL_Web 接口契约

ARM 推理程序与 Web 后端之间、Web 后端与浏览器之间的约定。与实现语言无关，推理侧只需发 HTTP POST。

板端官方实现为 Go 静态单文件（`backend/go/`），`backend/app.py`（Flask）为 PC 参考实现，
两者核心行为由 `tools/conformance.py` 比对。

## 接口一览

| 方法 | 路径 | 方向 | 用途 |
|---|---|---|---|
| POST | `/api/detections` | 推理程序 → 后端 | 上报三分类腐蚀严重度 |
| POST | `/api/nodes/online` | 推理程序 → 后端 | 批量注册节点上线 |
| GET | `/api/state` | 前端 → 后端 | 全量点位状态快照 |
| GET | `/api/network` | 前端 → 后端 | 管网拓扑 |
| GET | `/api/events` | 前端 ← 后端 | SSE 实时事件流 |
| GET | `/api/events/history` | 前端 → 后端 | 历史检测事件序列 |
| GET | `/api/health` | 调试 | 健康检查 |
| GET | `/api/system` | 前端 → 后端 | 平台/运行时长/CPU/内存/事件量 |
| GET | `/api/selfcheck` | 前端 → 后端 | 服务自检 |
| GET | `/api/alerts` | 前端 → 后端 | 告警列表 |
| POST | `/api/alerts/{id}/status` | 前端 → 后端 | 推进告警状态 |
| GET | `/api/stats/coverage` | 前端 → 后端 | 检测覆盖率（总体 + 分线） |
| GET | `/api/stats/top_severe` | 前端 → 后端 | 高危节点排名 |
| GET | `/api/stats/volatility` | 前端 → 后端 | 腐蚀波动度排名 |
| GET | `/api/stats/point_trend/{id}` | 前端 → 后端 | 单点严重度时间序列 |
| GET | `/api/points/{id}/captures` | 前端 → 后端 | 点位历史图像列表 |
| GET | `/captures/{file}` | 前端 ← 后端 | 历史图像文件 |
| GET | `/api/ledger` | 前端 → 后端 | 管道台账（Go 版） |

字段约定：

* `severity`：`0`=无腐蚀，`1`=轻度，`2`=重度（int），对应模型三分类 normal/light/severe
* `timestamp`：epoch 毫秒（int）；上报缺省由服务器补齐
* `point_id`：监测点编号（如 `P0431`），必须是 `/api/network` 中存在的编号

## POST /api/detections

支持批量与单条，`Content-Type` 不强制。

```bash
curl -X POST http://<板IP>:8080/api/detections \
  -d '{"items":[{"point_id":"P0431","severity":2},{"point_id":"P0432","severity":1}]}'

curl -X POST http://<板IP>:8080/api/detections -d '{"point_id":"P0001","severity":0}'
```

成功响应（HTTP 200，即使部分条目被拒）：

```json
{
  "accepted": 1,
  "rejected": [{"point_id": "P9999", "reason": "point_id 未知"}],
  "server_time": 1789286403018
}
```

校验：`point_id` 必须在拓扑中；`severity` 必须是 int 0/1/2（bool 不算）；
`timestamp` 非正整数时用服务器时间。被拒条目不影响其他条目。

推理侧参考实现（裸 socket，板上无 curl）：

```c
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

int report_detection(const char *host, int port, const char *point_id, int severity) {
    char body[128], req[512], resp[256];
    int n = snprintf(body, sizeof(body),
                     "{\"items\":[{\"point_id\":\"%s\",\"severity\":%d}]}",
                     point_id, severity);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    if (inet_pton(AF_INET, host, &a.sin_addr) != 1) { close(fd); return -2; }
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { close(fd); return -3; }
    snprintf(req, sizeof(req),
             "POST /api/detections HTTP/1.1\r\n"
             "Host: %s:%d\r\nContent-Type: application/json\r\n"
             "Content-Length: %d\r\nConnection: close\r\n\r\n%s",
             host, port, n, body);
    if (write(fd, req, n) < 0) { close(fd); return -4; }
    read(fd, resp, sizeof(resp));
    close(fd);
    return 0;
}
```

与 Web 同机时 `url` 用 `http://127.0.0.1:8080`（回环，不经网口）；板外联调时用 `http://<板IP>:8080`。

## GET /api/state

```json
{
  "server_time": 1789286161083,
  "points": {
    "P0500": {"severity": 2, "timestamp": 1789286160973, "online": true, "detected": true}
  }
}
```

只包含已上报或已注册的点（稀疏）。前端首载和 SSE 重连后各拉一次做全量恢复。
`online` 表示已上线（注册过或已有检测结果），`detected` 表示已有检测结果。

## GET /api/network

返回 `data/network.json` 原文：`meta`（bounds/点数/间距）、`lines`（管线折线）、
`stations`（站场）、`points`（id/坐标/所属管线/里程）。

## GET /api/events（SSE）

`text/event-stream`；`retry: 3000` 声明重连间隔；每 15s 一条心跳注释。

```
data: {"type":"hello","server_time":...}
data: {"type":"detection","items":[{"point_id":"P0431","severity":2,"timestamp":...}]}
data: {"type":"alert"}
data: {"type":"online"}
```

`alert`/`online` 表示状态有变化，前端收到后按需拉取对应接口。

## POST /api/nodes/online

```bash
curl -X POST http://<板IP>:8080/api/nodes/online -d '{"items":["P0001","P0002"]}'
# {"online":2,"unknown":0}
```

注册后的节点显示为蓝色"在线待检"，收到检测结果后按严重度着色；未检测的上线节点不触发离线告警。

## 告警规则

1. 突发严重腐蚀：某点 severity 升到 2（含首测即重度）。
2. 节点意外离线：已有数据的点超过 `--offline-minutes` 无更新，恢复后自动转"已修复"。
3. 区片聚合：同一条管线、里程相邻（不超过 800m）的重度告警合并为一条 `cluster` 告警，
   `type_text` 为"XX线区片腐蚀"，`range_text` 为首末节点（如 `P0260~P0285`），
   相邻点后续升重度时扩展该告警而非新建；离线告警仍为点级。

告警状态：待处理 → 处理中 → 已修复（点击状态 chip 逐级推进）。

## GET /api/events/history

```bash
curl "http://<板IP>:8080/api/events/history?until=1793290000000"
```

可选参数 `since`/`until`（epoch 毫秒，`until` 缺省为当前时刻）；
返回 `{"events":[{point_id,severity,timestamp}...],"count":N}`，按时间升序，上限 50,000 条（超出取最新）。
前端时间机器一次拉取后在本地重建任意时刻快照。

## 点位历史磁漏图像

图像放 `data/captures/`，命名 `<point_id>_<seq>.<ext>`（如 `P0431_003.png`，seq 越大越新），
支持 png/jpg/jpeg/bmp/gif：

```json
{"point_id": "P0431",
 "captures": [{"file": "P0431_003.png", "seq": 3, "time": 1789305122244,
               "url": "/captures/P0431_003.png"}]}
```

按 seq 降序返回。把符合命名规则的图像拷入该目录即可接入。

## 系统自检

`GET /api/selfcheck` 返回服务本体健康数据：平台/运行时/协程数、堆内存、启动时刻与运行时长、
事件总量与 60s/5s 上报速率、事件日志体积、历史图像统计、SSE 客户端数、未处理告警数，
以及组件自检清单（拓扑/事件日志/图像目录/上报链路/前端推送/告警积压/离线节点，状态 ok/warn）。

## 联调节奏

1. 后端起好后先灌 2 条，确认点位变色；
2. 按本接口批量灌入若干点位，核对告警、统计与历史图像；
3. 推理程序按本契约接入（同机回环地址）。
