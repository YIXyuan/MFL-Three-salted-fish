#!/bin/bash

set -e
cd "$(dirname "$0")"

GO=go
if ! command -v go >/dev/null 2>&1; then
  for c in "$HOME/go-sdk/go/bin/go" "/usr/local/go/bin/go"; do
    [ -x "$c" ] && GO="$c" && break
  done
fi
echo "使用工具链: $GO ($($GO version))"

mkdir -p bin

GIT_HEAD=$(git -C ../.. rev-parse --short HEAD 2>/dev/null || echo unknown)
CODE_HEAD=$(git -C ../.. log -1 --format=%h --   'backend/go/*.go' 'backend/go/go.mod' 'backend/run.sh' 'frontend' 'data/network.json'   2>/dev/null || echo unknown)
BUILD_AT=$(date "+%Y-%m-%d %H:%M:%S")
cat > bin/BUILD_INFO.txt <<INFO
build_at:   $BUILD_AT
git_head:   $GIT_HEAD
code_head:  $CODE_HEAD
artifacts:  mflweb(.exe) / mflweb-linux-arm64 / mflweb-board.tar.gz
contains:   POST /api/nodes/online, GET+POST /api/progress, GET /api/events/history
note:       判据看 code_head——它落后于该路径集的最新提交时才需重编；
            git_head 仅作人工回溯（纯文档提交不影响包内容）
md5 判据:   本脚本带 -buildvcs=false，同源码重编字节一致，md5 可当包身份；
            若去掉该参数，二进制会随 git 状态变化（vcs.* 入包），md5 不可比。
            tar.gz 自身 md5 每次构建都不同（内含 build_at 与构建时刻的 mtime），
            核对包内容请解包比对 md5_arm64，勿以 tar 的 md5 作判据
INFO
cat bin/BUILD_INFO.txt

if [ -n "$(git -C ../.. status --porcelain 2>/dev/null)" ]; then
  echo "⚠ 工作区有未提交改动：正式发布到 bin/ 前请先提交，否则 BUILD_INFO 的提交号与实际内容不符"
fi

"$GO" build -trimpath -buildvcs=false -ldflags "-s -w" -o bin/mflweb.exe . 2>/dev/null ||
  "$GO" build -trimpath -buildvcs=false -ldflags "-s -w" -o bin/mflweb .

CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
  "$GO" build -trimpath -buildvcs=false -ldflags "-s -w" -o bin/mflweb-linux-arm64 .

MD5_EXE=$(md5sum bin/mflweb.exe 2>/dev/null | awk '{print $1}' || true)
MD5_ARM=$(md5sum bin/mflweb-linux-arm64 2>/dev/null | awk '{print $1}' || true)
[ -n "$MD5_EXE" ] || MD5_EXE=unknown
[ -n "$MD5_ARM" ] || MD5_ARM=unknown
printf 'md5_exe:    %s\nmd5_arm64:  %s\n' "$MD5_EXE" "$MD5_ARM" >> bin/BUILD_INFO.txt

STAGE=$(mktemp -d)
cp bin/mflweb-linux-arm64 "$STAGE"/
cp ../run.sh "$STAGE"/
cp bin/BUILD_INFO.txt "$STAGE"/
cp -r ../../frontend "$STAGE"/frontend
mkdir -p "$STAGE/data"
cp ../../data/network.json "$STAGE/data/"
tar -czf bin/mflweb-board.tar.gz -C "$STAGE" .
rm -rf "$STAGE"

ls -la bin/
echo "完成：bin/mflweb(.exe) 本机版；bin/mflweb-linux-arm64 板端版；bin/mflweb-board.tar.gz 一键部署包"
