#!/bin/sh
# 最终验证：与插件完全一致的行为（IP 轮换 + 回退取流 + mpv + 每秒 status 轮询）
set -u
HOST=music-api.gdstudio.xyz
SOCK=/tmp/gdmusic.sock
IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl
IPS="104.18.0.1 104.17.0.1 104.19.0.1"

api() {
    for ip in $IPS; do
        r=$(curl -s --max-time 4 -A 'Mozilla/5.0' --resolve "$HOST:443:$ip" "https://$HOST/api.php?$1" 2>/dev/null)
        case "$r" in [*|{*) printf '%s' "$r"; return 0;; esac
    done
    return 1
}

pkill -f '[i]nput-ipc-server=' 2>/dev/null
pkill -f '[u]serdisk/mpv' 2>/dev/null
rm -f "$SOCK"
sleep 1

echo "== 1) 搜索 + 回退取流 =="
IDS=$(api "types=search&source=netease&name=%E5%91%A8%E6%9D%B0%E4%BC%A6&count=5&pages=1" \
      | tr '{' '\n' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
U=""; HIT=""
for id in $IDS; do
    u=$(api "types=url&source=netease&id=$id&br=320" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
    if [ -n "$u" ]; then U="$u"; HIT="$id"; break; fi
    echo "   id=$id 无链接，回退"
done
[ -z "$U" ] && { echo "FAIL 全部候选无链接"; exit 1; }
echo "   命中 id=$HIT"

echo "== 2) 启动 mpv =="
rm -f /tmp/m.log "$SOCK"
nohup /userdisk/mpv/mpv --no-video --force-window=no --idle=yes --volume=80 \
      --input-ipc-server="$SOCK" "$U" >/tmp/m.log 2>&1 &
i=0; while [ $i -lt 80 ]; do [ -S "$SOCK" ] && break; i=$((i+1)); sleep 0.25; done
[ -S "$SOCK" ] || { echo "FAIL socket 未创建"; exit 1; }

echo "== 3) 模拟插件每秒轮询 12 次（pause|pos|dur|idle） =="
for n in $(seq 1 12); do
    sleep 1
    printf "  #%-2s " "$n"
    LC_ALL=C "$IPC" "$SOCK" status
done

echo "== 4) 暂停 / 定位 / 复核 =="
LC_ALL=C "$IPC" "$SOCK" cmd set_property pause true >/dev/null
LC_ALL=C "$IPC" "$SOCK" cmd seek 60 absolute >/dev/null
sleep 2
printf "   复核  "; LC_ALL=C "$IPC" "$SOCK" status

echo "== 5) 清理 =="
LC_ALL=C "$IPC" "$SOCK" cmd quit >/dev/null 2>&1
sleep 1
pkill -f '[i]nput-ipc-server=' 2>/dev/null
pkill -f '[u]serdisk/mpv' 2>/dev/null
rm -f "$SOCK"
echo "== 验证结束 =="
