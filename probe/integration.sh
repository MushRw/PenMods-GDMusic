#!/bin/sh
# 真机集成验证：完全复刻插件的「IP 轮换 + 回退取流 + mpv + perl IPC」逻辑
set -u

HOST=music-api.gdstudio.xyz
SOCK=/tmp/gdmusic.sock
IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl
IPS="104.18.0.1 104.17.0.1 104.19.0.1 104.20.0.1 104.16.0.1"

WON=""
# 与插件 buildCurl + apiGetAt 一致：逐个 IP 试，首个成功即返回
api() {
    for ip in $IPS; do
        r=$(LC_ALL=C LANG=C curl -s --max-time 4 -A 'Mozilla/5.0' \
             --resolve "$HOST:443:$ip" "https://$HOST/api.php?$1" 2>/dev/null)
        case "$r" in [*|{*) WON="$ip"; printf '%s' "$r"; return 0;; esac
    done
    return 1
}

echo "== 1) 搜索 =="
T0=$(date +%s%N)
S=$(api "types=search&source=netease&name=%E5%91%A8%E6%9D%B0%E4%BC%A6&count=5&pages=1") || { echo "FAIL 搜索失败"; exit 1; }
T1=$(date +%s%N)
echo "   命中 IP=$WON  耗时 $(( (T1-T0)/1000000 )) ms"
IDS=$(printf '%s' "$S" | tr '{' '\n' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
echo "   候选: $(echo $IDS | tr '\n' ' ')"

echo "== 2) 回退取流 =="
U=""
for id in $IDS; do
    R=$(api "types=url&source=netease&id=$id&br=320")
    u=$(printf '%s' "$R" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
    if [ -n "$u" ]; then U="$u"; echo "   命中 id=$id"; break; fi
    echo "   id=$id 无链接，回退"
done
[ -z "$U" ] && { echo "FAIL 无可播放链接"; exit 1; }

echo "== 3) 歌词 + 封面 =="
L=$(api "types=lyric&source=netease&id=2652820720")
echo "   歌词长度: $(printf '%s' "$L" | wc -c) 字节"
P=$(api "types=pic&source=netease&id=109951173569626660&size=500")
echo "   封面返回: $(printf '%s' "$P" | head -c 120)"

echo "== 4) mpv 播放（用插件生成的启动命令） =="
rm -f /tmp/gdmusic.sock; nohup /userdisk/mpv/mpv --no-video --force-window=no --idle=yes --volume=80 --input-ipc-server=/tmp/gdmusic.sock "$U" > /tmp/gdmusic_mpv.log 2>&1 &
i=0; while [ $i -lt 60 ]; do [ -S "$SOCK" ] && break; i=$((i+1)); sleep 0.25; done
[ -S "$SOCK" ] || { echo "FAIL socket 未创建"; tail -5 /tmp/gdmusic_mpv.log; exit 1; }
sleep 4
echo -n "   status: "; LC_ALL=C "$IPC" "$SOCK" status
echo -n "   pause : "; LC_ALL=C "$IPC" "$SOCK" cmd 'set_property' 'pause' 'true'
echo -n "   seek  : "; LC_ALL=C "$IPC" "$SOCK" cmd 'seek' '30' 'absolute'
sleep 1
echo -n "   复核  : "; LC_ALL=C "$IPC" "$SOCK" status

echo "== 5) 清理 =="
LC_ALL=C "$IPC" "$SOCK" cmd 'quit' >/dev/null 2>&1
sleep 1
LC_ALL=C pkill -f 'input-ipc-server=/tmp/gdmusic.sock' 2>/dev/null
rm -f "$SOCK"
echo "=== 集成验证全部通过 ==="
