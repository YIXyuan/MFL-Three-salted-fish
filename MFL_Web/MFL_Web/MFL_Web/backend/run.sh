#!/bin/sh

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/mflweb-linux-arm64"
[ -x "$BIN" ] || BIN="$DIR/mflweb"

if command -v pkill >/dev/null 2>&1; then
    pkill -f mflweb-linux-arm64 2>/dev/null
else
    killall mflweb-linux-arm64 2>/dev/null
fi
sleep 0.3

nohup "$BIN" --host 0.0.0.0 --port 8080 --offline-minutes 30 --log-file "$DIR/mflweb.log" \
    >/dev/null 2>&1 &
echo "mflweb started, pid $!"
sleep 0.5

wget -qO- "http://127.0.0.1:8080/api/health" && echo || echo "警告：健康检查未通过，查看 $DIR/mflweb.log"
