#!/bin/sh
# 验证：GD API 搜索 -> 逐个试流(带回退) -> mpv 播放 -> perl 走 JSON-IPC 控制
set -u

SOCK=/tmp/gdipc.sock
IPC=/tmp/gdipc.pl
B="https://music-api.gdstudio.xyz/api.php"
UA="Mozilla/5.0"

rm -f "$SOCK"
pkill -f "input-ipc-server=$SOCK" 2>/dev/null

echo "== 1) 搜索 =="
IDS=$(curl -s --max-time 30 -A "$UA" "$B?types=search&source=netease&name=%E6%99%B4%E5%A4%A9&count=5" \
      | tr '{' '\n' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
echo "拿到候选 id: $(echo $IDS | tr '\n' ' ')"

echo "== 2) 逐个试流 =="
U=""
for id in $IDS; do
    r=$(curl -s --max-time 30 -A "$UA" "$B?types=url&source=netease&id=$id&br=320")
    u=$(echo "$r" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
    if [ -n "$u" ]; then
        U="$u"
        echo "OK id=$id 命中"
        break
    fi
    echo "   id=$id 无链接，回退下一个"
done
if [ -z "$U" ]; then echo "FAIL: 所有候选都取不到 url"; exit 1; fi
echo "url 前 70 字符: $(echo "$U" | cut -c1-70)"

echo "== 3) 启动 mpv (IPC=$SOCK) =="
nohup /userdisk/mpv/mpv --no-video --force-window=no --idle=yes \
      --input-ipc-server="$SOCK" "$U" > /tmp/gdmpv.log 2>&1 &

i=0
while [ $i -lt 60 ]; do
    [ -S "$SOCK" ] && break
    i=$((i + 1)); sleep 0.25
done
if [ ! -S "$SOCK" ]; then echo "FAIL: socket 未创建"; tail -5 /tmp/gdmpv.log; exit 1; fi
echo "OK socket 就绪"

echo "== 4) IPC 查询 =="
sleep 3
echo -n "  duration -> "; perl "$IPC" "$SOCK" '{"command":["get_property","duration"],"request_id":1}'
echo -n "  time-pos -> "; perl "$IPC" "$SOCK" '{"command":["get_property","time-pos"],"request_id":2}'
echo -n "  media-title -> "; perl "$IPC" "$SOCK" '{"command":["get_property","media-title"],"request_id":3}'

echo "== 5) IPC 暂停 =="
echo -n "  set pause=true -> "; perl "$IPC" "$SOCK" '{"command":["set_property","pause",true],"request_id":4}'
sleep 1
echo -n "  get pause -> "; perl "$IPC" "$SOCK" '{"command":["get_property","pause"],"request_id":5}'

echo "== 6) IPC 音量 + 定位 =="
echo -n "  volume 60 -> "; perl "$IPC" "$SOCK" '{"command":["set_property","volume",60],"request_id":6}'
echo -n "  seek 30 -> "; perl "$IPC" "$SOCK" '{"command":["seek",30,"absolute"],"request_id":7}'

echo "== 7) 退出 =="
perl "$IPC" "$SOCK" '{"command":["quit"],"request_id":8}' >/dev/null 2>&1
sleep 1
if pgrep -f "input-ipc-server=$SOCK" >/dev/null 2>&1; then
    echo "WARN: mpv 仍在运行，强制结束"; pkill -f "input-ipc-server=$SOCK"
else
    echo "OK mpv 已退出"
fi
echo "=== 探针完成 ==="
