#!/bin/sh
# 用确定可取的曲子，隔离「声卡 vs 网络流」验证 time-pos 是否推进
set -u
HOST=music-api.gdstudio.xyz
IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl
IPS="104.18.0.1 104.17.0.1 104.19.0.1"

api() {
    for ip in $IPS; do
        r=$(LC_ALL=C curl -s --max-time 10 -A 'Mozilla/5.0' --resolve "$HOST:443:$ip" "https://$HOST/api.php?$1" 2>/dev/null)
        case "$r" in "["*|"{"*) printf '%s' "$r"; return 0;; esac
    done
    return 1
}

pkill -f '[i]nput-ipc-server=' 2>/dev/null
pkill -f '[u]serdisk/mpv' 2>/dev/null
sleep 1

IDS="2652820720 2668397359 210049 509781655 490595315"
U=""
for id in $IDS; do
    u=$(api "types=url&source=netease&id=$id&br=320" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
    if [ -n "$u" ]; then U="$u"; HIT="$id"; break; fi
    echo "  id=$id 取不到，回退"
done
[ -z "$U" ] && { echo "无可用 url"; exit 1; }
echo "命中 id=$HIT"

echo "== 预下载本地副本 =="
curl -s --max-time 40 -r 0-3000000 -o /tmp/local.test "$U"
echo "  本地大小 $(wc -c < /tmp/local.test) 字节"

case_run() {
    label="$1"; tag="$2"; shift 2
    SOCK="/tmp/gd_$tag.sock"
    rm -f "$SOCK" /tmp/case_$tag.log
    echo "== $label =="
    nohup /userdisk/mpv/mpv --no-video --force-window=no --idle=yes --volume=80 \
          --input-ipc-server="$SOCK" "$@" >/tmp/case_$tag.log 2>&1 &
    i=0; while [ $i -lt 60 ]; do [ -S "$SOCK" ] && break; i=$((i+1)); sleep 0.25; done
    sleep 6
    printf "   t1 "; LC_ALL=C "$IPC" "$SOCK" cmd get_property time-pos
    sleep 4
    printf "   t2 "; LC_ALL=C "$IPC" "$SOCK" cmd get_property time-pos
    sleep 4
    printf "   t3 "; LC_ALL=C "$IPC" "$SOCK" cmd get_property time-pos
    echo "   AO: $(grep -E 'AO:|Audio --' /tmp/case_$tag.log | tail -1)"
    LC_ALL=C "$IPC" "$SOCK" cmd quit >/dev/null 2>&1
    sleep 1
    pkill -f "[i]nput-ipc-server=$SOCK" 2>/dev/null
    rm -f "$SOCK"
}

case_run "A: 本地文件 + 默认声卡" A /tmp/local.test
case_run "B: 网络流   + ao=null" B --ao=null "$U"
case_run "C: 网络流   + 默认声卡" C "$U"
echo "== 结束 =="
