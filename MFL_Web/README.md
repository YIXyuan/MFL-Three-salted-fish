# MFL_Web — 管道漏磁腐蚀监测大屏

独立的 Web 前后端子项目。板端运行 Go 静态单文件后端（零 Python 依赖），PC 浏览器经以太网访问大屏；
ARM 推理程序把三分类腐蚀严重度上报到本机回环，大屏在管网热力图上按点位实时渲染，并产生告警、统计与历史回看。

```
PC 浏览器（哑显示终端，只渲染页面）──以太网──> 板子:8080（Go 静态二进制）
                                                    ↑ 本机回环 POST
                                                ARM 推理程序（C）← FPGA
```

板端 rootfs 没有 Python、没有 curl，因此后端用 Go 纯标准库实现；`backend/app.py`（Flask）保留为 PC 参考实现，
两版核心行为由 `tools/conformance.py` 逐项比对。

严重度语义：`0`=无腐蚀（绿）、`1`=轻度（黄）、`2`=重度（红），灰=未检测。

## 目录结构

```
MFL_Web/
├── backend/
│   ├── go/                 板端后端（Go，纯标准库）
│   │   ├── main.go         启动参数、目录探测、自动上线、离线扫描
│   │   ├── api.go          路由表
│   │   ├── core.go         点位状态、事件日志、告警与区片聚合
│   │   ├── stats.go        覆盖率、高危排名、波动度、单点趋势
│   │   ├── captures.go     历史图像索引与文件服务
│   │   ├── ledger.go       管道台账接口
│   │   ├── selfcheck.go    服务自检
│   │   ├── static.go       前端静态文件与 SSE
│   │   ├── build.sh        构建 PC / linux-arm64 / 板端部署包
│   │   └── bin/            构建产物（arm64 二进制、部署包、构建信息）
│   ├── app.py              Flask 参考实现（PC 联调）
│   ├── requirements.txt    Flask 参考实现的依赖
│   └── run.sh              板端启动脚本
├── docs/
│   └── API.md              完整接口契约（字段、请求示例、SSE、告警规则）
├── frontend/
│   ├── index.html          大屏布局（右三区 + 底栏，data-slot 可扩展）
│   ├── css/main.css
│   ├── js/                 app / view / heatmap / panels / history / preview /
│   │                       search / selfcheck / timemachine
│   └── assets/satellite.jpg
├── data/
│   ├── network.json        管网拓扑：11 条管线、370km、1861 个监测点（200m 等距）、41 座站场
│   └── ledger.json         管道台账
└── tools/
    ├── conformance.py      Flask 与 Go 一致性比对
    ├── gen_network.py      生成管网拓扑
    └── gen_ledger.py       生成管道台账
```

`data/captures/` 为用户自备的点位历史磁漏图像目录，缺省不存在，按需创建。
完整接口契约见 `docs/API.md`。

## 快速开始（PC）

```bash
pip install -r backend/requirements.txt
python backend/app.py --port 8080
# 浏览器打开 http://127.0.0.1:8080
```

也可以直接用 Go 产物：`bash backend/go/build.sh` 后在 `backend/go/bin/` 下运行 `mflweb.exe`（PC）
或 `mflweb-linux-arm64`（板端）。构建脚本同时产出板端一键部署包 `mflweb-board.tar.gz`（二进制 + run.sh +
frontend + data/network.json）。

前端支持 URL 参数 `?zoom=max`，初始即最大比例。

## 板端部署

部署包已包含运行所需的全部文件：

```bash
scp backend/go/bin/mflweb-board.tar.gz root@<板IP>:/root/
ssh root@<板IP>
mkdir -p /root/mflweb
gunzip -c /root/mflweb-board.tar.gz | tar -x -C /root/mflweb   # busybox tar 不支持 -z
cd /root/mflweb && chmod +x mflweb-linux-arm64 run.sh
./run.sh                       # 启动并用 busybox wget 打 /api/health
```

分文件部署：

```bash
scp backend/go/bin/mflweb-linux-arm64 backend/run.sh root@<板IP>:/root/mflweb/
scp -r frontend root@<板IP>:/root/mflweb/
ssh root@<板IP> "mkdir -p /root/mflweb/data"
scp data/network.json root@<板IP>:/root/mflweb/data/
```

`run.sh` 默认 `--host 0.0.0.0 --port 8080 --offline-minutes 30`，日志写入 `mflweb.log`。
绕过 run.sh 手动启动时请自行带上离线阈值参数：

```bash
nohup ./mflweb-linux-arm64 --host 0.0.0.0 --port 8080 --offline-minutes 30 --log-file ./mflweb.log &
```

### 开机自启

板上新建 `/etc/init.d/S99mflweb` 并 `chmod +x`：

```sh
#!/bin/sh
case "$1" in
  start) /root/mflweb/run.sh ;;
  stop)  killall mflweb-linux-arm64 2>/dev/null ;;
esac
```

板端为 busybox rcS，按文件名顺序执行 `/etc/init.d/S*`。若还有其他开机任务（FPGA、推理程序），
建议在本脚本的 start 分支里加一个短延时，或把本脚本编号排在它们之后。

### 验证

```bash
# 板上
wget -qO- http://127.0.0.1:8080/api/health

# PC 浏览器（与板子同网段）
http://<板IP>:8080

# PC 上灌数据联调
curl -X POST http://<板IP>:8080/api/detections -d '{"point_id":"P0001","severity":1}'
```

### 板端文件布局

```
/root/mflweb/
├── mflweb-linux-arm64    Go 静态二进制（约 6.5MB，不依赖板上库）
├── run.sh                启动/自检脚本
├── frontend/             大屏静态文件（改 HTML/JS 后刷新即生效）
├── data/network.json     管网拓扑（重启进程生效）
├── data/captures/        点位历史磁漏图像（可选，命名 P0431_003.png）
├── event_log.jsonl       事件日志（启动时自动生成/续写，删除即清零）
└── mflweb.log            运行日志
```

事件日志写在进程当前工作目录；run.sh 会先 `cd` 到脚本目录再启动。

### 推理程序接入

与 Web 同机时上报地址用 `http://127.0.0.1:8080/api/detections`（回环）。板上没有 curl，
推理侧用裸 socket POST（`docs/API.md` 有 C 示例），临时测试可用 busybox wget：

```bash
wget -qO- --post-data='{"point_id":"P0001","severity":2}' \
  --header='Content-Type: application/json' http://127.0.0.1:8080/api/detections
```

### 板端环境约束

| 项目 | 实况 | 影响 |
|---|---|---|
| Python | 无 python/pip/包管理器 | 板上不能跑 Flask，使用 Go 静态二进制 |
| 系统 | Buildroot 2022.08.1 同版，glibc 2.25，内核 5.10 | 静态编译规避依赖 |
| 显示 | 无 /dev/fb0、无 /dev/dri | 大屏由 PC 浏览器渲染 |
| 网络 | eth0 DHCP；有 wget/scp/ssh，无 curl | 上报用裸 socket 或 wget |
| 资源 | RAM 422MB；root 分区剩余 53.7G | Go 版常驻内存约 25MB |
| 自启 | busybox rcS，`/etc/init.d/S*` | 加 S99mflweb 即可 |

### 离线阈值

板端推理单帧耗时较长，普通点两次上报的间隔可达 10~20 分钟，`--offline-minutes 30` 可避免误报离线；
代码默认值 10 分钟仅适用于 PC 高频灌图联调。现场轮次间有长时间停顿时可再调大。

## 接口契约

推理程序与后端之间只依赖 HTTP POST，与实现语言无关。板上没有 curl 时用裸 socket 发 POST 即可。

### 通用约定

* `severity`：int，`0`=无腐蚀、`1`=轻度、`2`=重度，与模型三分类 normal/light/severe 对应
* `timestamp`：epoch 毫秒；上报缺省时由服务器补齐
* `point_id`：监测点编号（如 `P0431`），必须在 `/api/network` 的拓扑中存在

### 接口一览

| 方法 | 路径 | 用途 |
|---|---|---|
| POST | `/api/detections` | 上报检测结果（支持单条与批量） |
| POST | `/api/nodes/online` | 批量注册节点上线 |
| GET | `/api/state` | 全量点位状态快照 |
| GET | `/api/network` | 管网拓扑 |
| GET | `/api/events` | SSE 实时事件流 |
| GET | `/api/events/history` | 历史检测事件序列（时间机器回看） |
| GET | `/api/health` | 健康检查 |
| GET | `/api/system` | 平台、运行时长、CPU/内存、事件量 |
| GET | `/api/selfcheck` | 服务自检（组件状态与上报速率） |
| GET | `/api/alerts` | 告警列表 |
| POST | `/api/alerts/{id}/status` | 推进告警状态 |
| GET | `/api/stats/coverage` | 检测覆盖率（总体 + 分线） |
| GET | `/api/stats/top_severe` | 高危节点排名（历史重度次数 Top10） |
| GET | `/api/stats/volatility` | 腐蚀波动度排名 |
| GET | `/api/stats/point_trend/{id}` | 单点严重度时间序列 |
| GET | `/api/points/{id}/captures` | 点位历史图像列表 |
| GET | `/captures/{file}` | 历史图像文件 |
| GET | `/api/ledger` | 管道台账（Go 版） |

### POST /api/detections

```bash
# 批量（推荐）
curl -X POST http://<板IP>:8080/api/detections \
  -d '{"items":[{"point_id":"P0431","severity":2},{"point_id":"P0432","severity":1}]}'

# 单条
curl -X POST http://<板IP>:8080/api/detections -d '{"point_id":"P0001","severity":0}'
```

响应（HTTP 200，部分条目被拒也返回 200）：

```json
{
  "accepted": 1,
  "rejected": [{"point_id": "P9999", "reason": "point_id 未知"}],
  "server_time": 1789286403018
}
```

校验：`point_id` 必须在拓扑中；`severity` 必须是 int 0/1/2（bool 不算）；`timestamp` 非正整数时用服务器时间。
单条被拒不影响同批其他条目。

推理侧最小实现（裸 socket，无第三方依赖）：

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
    read(fd, resp, sizeof(resp));   /* 读到响应头即可 */
    close(fd);
    return 0;
}
```

与 Web 同机时 `host` 用 `127.0.0.1`（回环，不经网口）；板外联调用板子 IP。

### GET /api/state

```json
{
  "server_time": 1789286161083,
  "points": {
    "P0500": {"severity": 2, "timestamp": 1789286160973, "online": true, "detected": true},
    "P0501": {"severity": 1, "timestamp": 1789286160973, "online": true, "detected": true}
  }
}
```

只包含已上报或已注册的点（稀疏）。前端首次加载和 SSE 重连后各拉一次做全量恢复。

### GET /api/events（SSE）

`text/event-stream`，`retry: 3000`，每 15s 一条心跳注释。连接建立先发 `hello`：

```
data: {"type":"hello","server_time":...}
data: {"type":"detection","items":[{"point_id":"P0431","severity":2,"timestamp":...}]}
data: {"type":"alert"}
data: {"type":"online"}
```

`alert`、`online` 只表示状态有变化，前端收到后按需拉取对应接口。

### 告警规则

1. 突发严重腐蚀：某点 severity 升到 2（含首测即重度）。
2. 节点意外离线：已有数据的点超过 `--offline-minutes` 无更新；数据恢复后自动转"已修复"。
3. 区片聚合：同一条管线、里程相邻（不超过 800m）的重度告警合并为一条 `cluster` 告警，
   文案为"XX线区片腐蚀"，范围为首末节点（如 `P0260~P0285`），相邻点后续升重度时扩展该告警而非新建。
   离线告警仍为点级。

告警状态：`待处理 → 处理中 → 已修复`，前端点击状态 chip 逐级推进。

### 节点上线

```bash
curl -X POST http://<板IP>:8080/api/nodes/online -d '{"items":["P0001","P0002"]}'
# {"online":2,"unknown":0}
```

注册后的节点显示为蓝色"在线待检"，收到检测结果后按严重度着色；未检测的上线节点不触发离线告警。

### 历史磁漏图像

文件放在 `data/captures/`，命名 `<point_id>_<seq>.<ext>`（如 `P0431_003.png`，seq 越大越新），
支持 png/jpg/jpeg/bmp/gif：

```json
{"point_id":"P0431",
 "captures":[{"file":"P0431_003.png","seq":3,"time":1789305122244,
              "url":"/captures/P0431_003.png"}]}
```

按 seq 降序返回。把符合命名规则的图像拷进该目录即可接入，无需重启。

## 大屏功能

* 管网热力图：程序化伪卫星底图，2D / 2.5D 切换（2.5D 为圆柱管段、法兰环、深度排序）；
  点变色沿管线弧长 ±1000m 渐变，800ms 缓动与涟漪，重度点呼吸光晕。
* 缩放：滚轮以光标为中心连续缩放、拖拽平移、双击复位；缩放下限 1:10000（200m 点距约 2cm），比例尺实时显示。
* 点位详情：点击监测点（2D）或管段（2.5D）打开预览小窗，展示最新磁漏图与元数据；
  "查看全部 N 张历史"打开时间轴平铺弹窗（由旧到新，最新带徽标）。
* 告警：航班屏风格，突发重度与离线告警；状态 chip 流转；标题角标显示未处理数。
* 统计：高危节点 Top10、检测覆盖率、趋势分析（按腐蚀波动度排序）。
* 系统状态：监测点/在线节点/当前重度/未处理告警、严重度分布环形图、SSE 在线、ARM CPU/内存、
  运行平台与时长。
* 时间机器：拉取 `/api/events/history` 后本地重建任意时刻快照。

可调项：`frontend/js/heatmap.js` 顶部 `INFLUENCE_M`（渐变半径）、`TRANSITION_MS`；
`frontend/js/view.js` 的 `CSS_PX_PER_CM`（非 96dpi 屏幕时修正比例尺）；
拓扑参数在 `tools/gen_network.py` 顶部，改后需重新生成 `data/network.json` 并重启后端。

## 工具

```bash
# Flask 与 Go 行为比对（先执行 bash backend/go/build.sh 生成 bin/mflweb 或 mflweb.exe）
python tools/conformance.py
python tools/conformance.py --skip-flask

# 重新生成拓扑 / 台账
python tools/gen_network.py --scale 1.0
python tools/gen_ledger.py --seed 42
```

## 后端参数（Go / Flask 同名）

`--host`、`--port`、`--frontend`、`--data`、`--captures-dir`、`--eventlog`、`--no-eventlog`、
`--offline-minutes`、`--auto-online`（启动后自动把全部节点置为上线，默认开启）、`--log-file`；
Go 版另有 `--ledger`。路径缺省时自动探测相对目录。

## 常见问题

| 现象 | 处理 |
|---|---|
| PC 访问不到板子 | 板上 `wget -qO- http://127.0.0.1:8080/api/health`，确认服务与网段 |
| 端口被占 | 换端口启动，并同步修改自启脚本 |
| 改了前端没生效 | 静态文件带 no-store，刷新即可；改 Go 代码需重新构建并上传 |
| 统计数据想清零 | 停进程，删除 `event_log.jsonl`，重启 |
| 告警时间异常 | 板子无 RTC 时开机时间为 1970，使用前用 `date -s` 校时 |
| 没有板子想调大屏 | PC 上运行 `python backend/app.py`，浏览器访问本机 8080 |
