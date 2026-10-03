#!/bin/sh
# 端到端：优选 CF IP -> 搜索 -> 回退取流 -> mpv -> perl JSON-IPC 控制
set -u

SOCK=/tmp/gdipc.sock
IPC=/tmp/gdipc.pl
HOST=music-api.gdstudio.xyz
CF_IPS="104.18.32.47 104.17.0.1 162.159.140.1"
UA="Mozilla/5.0"

# 通过优选 IP 请求，逐个重试
api() {
    _q="$1"
    for ip in $CF_IPS; do
        _r=$(curl -s --max-time 10 --resolve "$HOST:443:$ip" -A "$UA" "https://$HOST/api.php?$_q" 2>/dev/null)
        if [ -n "$_r" ]; then printf '%s' "$_r"; return 0; fi
        echo "   [ip $ip 无响应，换下一个]" >&2
    done
    return 1
}

rm -f "$SOCK"
pkill -f "input-ipc-server=$SOCK" 2>/dev/null

echo "== 1) 搜索（走优选 IP） =="
S=$(api "types=search&source=netease&name=%E6%99%B4%E5%A4%A9&count=5") || { echo "FAIL: 搜索失败"; exit 1; }
IDS=$(printf '%s' "$S" | tr '{' '\n' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
echo "   候选: $(echo $IDS | tr '\n' ' ')"

echo "== 2) 逐个试流（回退） =="
U=""; HIT=""
for id in $IDS; do
    r=$(api "types=url&source=netease&id=$id&br=320")
    u=$(printf '%s' "$r" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
    if [ -n "$u" ]; then U="$u"; HIT="$id"; echo "   命中 id=$id"; break; fi
    echo "   id=$id 无链接，回退"
done
[ -z "$U" ] && { echo "FAIL: 全部候选无链接"; exit 1; }
echo "   url: $(echo "$U" | cut -c1-64)..."

echo "== 3) 启动 mpv =="
nohup /userdisk/mpv/mpv --no-video --force-window=no --idle=yes \
      --input-ipc-server="$SOCK" "$U" > /tmp/gdmpv.log 2>&1 &
i=0; while [ $i -lt 60 ]; do [ -S "$SOCK" ] && break; i=$((i+1)); sleep 0.25; done
[ -S "$SOCK" ] || { echo "FAIL: socket 未创建"; tail -5 /tmp/gdmpv.log; exit 1; }
echo "   socket 就绪"

echo "== 4) IPC 读取状态 =="
sleep 4
echo -n "   duration   -> "; perl "$IPC" "$SOCK" '{"command":["get_property","duration"],"request_id":1}'
echo -n "   time-pos   -> "; perl "$IPC" "$SOCK" '{"command":["get_property","time-pos"],"request_id":2}'
echo -n "   pause      -> "; perl "$IPC" "$SOCK" '{"command":["get_property","pause"],"request_id":3}'
echo -n "   volume     -> "; perl "$IPC" "$SOCK" '{"command":["get_property","volume"],"request_id":4}'

echo "== 5) IPC 控制 =="
echo -n "   暂停       -> "; perl "$IPC" "$SOCK" '{"command":["set_property","pause",true],"request_id":5}'
echo -n "   音量 60    -> "; perl "$IPC" "$SOCK" '{"command":["set_property","volume",60],"request_id":6}'
echo -n "   定位 30s   -> "; perl "$IPC" "$SOCK" '{"command":["seek",30,"absolute"],"request_id":7}'
sleep 1
echo -n "   复核 pause -> "; perl "$IPC" "$SOCK" '{"command":["get_property","pause"],"request_id":8}'
echo -n "   复核 pos   -> "; perl "$IPC" "$SOCK" '{"command":["get_property","time-pos"],"request_id":9}'

echo "== 6) 退出 =="
perl "$IPC" "$SOCK" '{"command":["quit"],"request_id":10}' >/dev/null 2>&1
sleep 1
if pgrep -f "input-ipc-server=$SOCK" >/dev/null 2>&1; then
    echo "   WARN mpv 未退出，强制结束"; pkill -f "input-ipc-server=$SOCK"
else
    echo "   mpv 已退出"
fi
echo "=== 端到端全部通过 ==="
