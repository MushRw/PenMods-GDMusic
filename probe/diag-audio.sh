#!/bin/sh
# 诊断：音频输出到底有没有跑起来（time-pos 是否自主推进）
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
rm -f "$SOCK"; sleep 1

IDS=$(api "types=search&source=netease&name=%E5%91%A8%E6%9D%B0%E4%BC%A6&count=5&pages=1" | tr '{' '\n' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
U=""
for id in $IDS; do
    u=$(api "types=url&source=netease&id=$id&br=320" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
    [ -n "$u" ] && { U="$u"; echo "id=$id"; break; }
done
[ -z "$U" ] && { echo "无 url"; exit 1; }

echo "== 场景 A：--idle=yes（插件当前用法） =="
rm -f /tmp/mA.log "$SOCK"
nohup /userdisk/mpv/mpv --no-video --force-window=no --idle=yes --msg-level=all=info \
      --volume=80 --input-ipc-server="$SOCK" "$U" >/tmp/mA.log 2>&1 &
i=0; while [ $i -lt 80 ]; do [ -S "$SOCK" ] && break; i=$((i+1)); sleep 0.25; done
sleep 8
echo "  AO/音频相关日志:"; grep -E "AO:|Audio|audio|Cannot|Failed|error" /tmp/mA.log | head -8
echo -n "  t1 time-pos: "; LC_ALL=C "$IPC" "$SOCK" cmd get_property time-pos
sleep 6
echo -n "  t2 time-pos: "; LC_ALL=C "$IPC" "$SOCK" cmd get_property time-pos
LC_ALL=C "$IPC" "$SOCK" cmd quit >/dev/null 2>&1; sleep 1
pkill -f '[i]nput-ipc-server=' 2>/dev/null; rm -f "$SOCK"

echo "== 场景 B：不加 --idle（对照） =="
rm -f /tmp/mB.log "$SOCK"
nohup /userdisk/mpv/mpv --no-video --force-window=no --msg-level=all=info \
      --volume=80 --input-ipc-server="$SOCK" "$U" >/tmp/mB.log 2>&1 &
i=0; while [ $i -lt 80 ]; do [ -S "$SOCK" ] && break; i=$((i+1)); sleep 0.25; done
sleep 8
echo "  AO/音频相关日志:"; grep -E "AO:|Audio|audio|Cannot|Failed|error" /tmp/mB.log | head -8
echo -n "  t1 time-pos: "; LC_ALL=C "$IPC" "$SOCK" cmd get_property time-pos
sleep 6
echo -n "  t2 time-pos: "; LC_ALL=C "$IPC" "$SOCK" cmd get_property time-pos
LC_ALL=C "$IPC" "$SOCK" cmd quit >/dev/null 2>&1; sleep 1
pkill -f '[i]nput-ipc-server=' 2>/dev/null; rm -f "$SOCK"
echo "== 结束 =="
