#!/bin/sh
# 最终验证：确认音频真的在推进（time-pos 自主增长）
set -u
HOST=music-api.gdstudio.xyz
SOCK=/tmp/gdmusic.sock
IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl
IPS="104.18.0.1 104.17.0.1 104.19.0.1 104.20.0.1 104.16.0.1"

# 与插件 buildApiCmdForIps 同样的逻辑：逐 IP 试，首个成功即用
api() {
    qs="$1"
    for ip in $IPS; do
        r=$(LC_ALL=C curl -s --max-time 6 -A 'Mozilla/5.0' \
            --resolve "$HOST:443:$ip" "https://$HOST/api.php?$qs" 2>/dev/null)
        case "$r" in "["*|"{"*) printf '%s' "$r"; return 0;; esac
    done
    r=$(LC_ALL=C curl -s --max-time 6 -A 'Mozilla/5.0' "https://$HOST/api.php?$qs" 2>/dev/null)
    case "$r" in "["*|"{"*) printf '%s' "$r"; return 0;; esac
    return 1
}

pkill -f '[i]nput-ipc-server=' 2>/dev/null
pkill -f '[u]serdisk/mpv' 2>/dev/null
rm -f "$SOCK"; sleep 1

echo "== 搜索 =="
IDS=$(api "types=search&source=netease&name=%E5%91%A8%E6%9D%B0%E4%BC%A6&count=6&pages=1" \
      | tr '{' '\n' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
echo "  候选: $(echo $IDS | tr '\n' ' ')"

U=""; HIT=""
for id in $IDS; do
    u=$(api "types=url&source=netease&id=$id&br=320" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
    if [ -n "$u" ]; then U="$u"; HIT="$id"; break; fi
    echo "  id=$id 无链接，回退"
done
[ -z "$U" ] && { echo "FAIL 无可用链接"; exit 1; }
echo "  命中 id=$HIT"

echo "== 启动 mpv 并观察 8 秒 =="
rm -f /tmp/mf.log "$SOCK"
nohup /userdisk/mpv/mpv --no-video --force-window=no --idle=yes --volume=80 \
      --input-ipc-server="$SOCK" "$U" >/tmp/mf.log 2>&1 &
i=0; while [ $i -lt 80 ]; do [ -S "$SOCK" ] && break; i=$((i+1)); sleep 0.25; done
[ -S "$SOCK" ] || { echo "FAIL socket"; exit 1; }

prev=""
for n in $(seq 1 8); do
    sleep 1
    st=$(LC_ALL=C "$IPC" "$SOCK" status)
    printf "  #%-2s %s\n" "$n" "$st"
    cur=$(printf '%s' "$st" | cut -d'|' -f2)
    if [ -n "$prev" ] && [ "$cur" != "null" ] && [ "$prev" != "null" ] && [ "$cur" != "$prev" ]; then
        echo "       ↑ time-pos 在推进 ✅"
    fi
    [ "$cur" != "null" ] && prev="$cur"
done

echo "== 音频输出日志 =="
grep -E 'AO:|Audio|Cannot|Failed|error' /tmp/mf.log | head -6 || echo "  (无)"

echo "== 清理 =="
LC_ALL=C "$IPC" "$SOCK" cmd quit >/dev/null 2>&1
sleep 1
pkill -f '[i]nput-ipc-server=' 2>/dev/null
pkill -f '[u]serdisk/mpv' 2>/dev/null
rm -f "$SOCK"
echo "== 结束 =="
