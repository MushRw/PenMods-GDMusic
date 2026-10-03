#!/bin/sh
# 播完（EOF）时 mpv 的状态：验证 keep-open=always（来自包装脚本强制的 mpv.conf）
# 是否会让 idle-active 永远为 false，从而破坏插件的「自动连播」判据。
SOCK=/tmp/gdmusic.sock
IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl
HOST=music-api.gdstudio.xyz
IPS="104.18.0.1 104.17.0.1 104.19.0.1 104.20.0.1 104.16.0.1"

api() {
    for ip in $IPS; do
        r=$(LC_ALL=C curl -s --max-time 6 -A 'Mozilla/5.0' --resolve "$HOST:443:$ip" "https://$HOST/api.php?$1" 2>/dev/null)
        case "$r" in "["*|"{"*) printf '%s' "$r"; return 0;; esac
    done
    return 1
}
prop() { LC_ALL=C "$IPC" "$SOCK" raw "{\"command\":[\"get_property\",\"$1\"],\"request_id\":1}" \
         | sed -n 's/.*"data":\([^,}]*\).*/\1/p'; }

U=""
for id in $(api "types=search&source=netease&name=%E5%91%A8%E6%9D%B0%E4%BC%A6&count=6&pages=1" | tr '{' '\n' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p'); do
    u=$(api "types=url&source=netease&id=$id&br=320" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
    [ -n "$u" ] && { U="$u"; break; }
done
[ -z "$U" ] && { echo "无可用链接"; exit 1; }
echo "URL ok"

trial() {
    label="$1"; extra="$2"
    echo
    echo "=================== $label ==================="
    pkill -f '[i]nput-ipc-server='"$SOCK" 2>/dev/null; rm -f "$SOCK"; sleep 1
    # shellcheck disable=SC2086
    nohup /userdisk/mpv/mpv --no-video --force-window=no --idle=yes --volume=0 \
          --input-ipc-server="$SOCK" $extra "$U" >/tmp/eof_mpv.log 2>&1 &
    i=0; while [ $i -lt 60 ]; do [ -S "$SOCK" ] && break; i=$((i+1)); sleep 0.25; done
    [ -S "$SOCK" ] || { echo "  socket 失败"; return; }

    # 等 duration 出来
    d=""; n=0
    while [ $n -lt 20 ]; do d=$(LC_ALL=C "$IPC" "$SOCK" status | cut -d'|' -f3); [ "$d" != "null" ] && [ -n "$d" ] && break; n=$((n+1)); sleep 1; done
    echo "  duration=$d  keep-open=$(prop keep-open)"
    # 跳到距结尾 4 秒（mpv 没有 absolute-end 模式，必须算绝对位置）
    e=$(awk -v d="$d" 'BEGIN{printf "%.0f", d-4}')
    echo "  seek -> $e absolute"
    LC_ALL=C "$IPC" "$SOCK" cmd seek "$e" absolute >/dev/null 2>&1
    sleep 1
    echo "  --- EOF 前后逐秒采样 ---"
    for n in $(seq 1 12); do
        st=$(LC_ALL=C "$IPC" "$SOCK" status)
        printf "   t+%-2s pause|pos|dur|idle = %s   eof-reached=%s\n" "$n" "$st" "$(prop eof-reached)"
        sleep 1
    done
    pkill -f '[i]nput-ipc-server='"$SOCK" 2>/dev/null; rm -f "$SOCK"
}

trial "A. 现状：走包装脚本（config 里 keep-open=always 生效）" ""
trial "B. 修复：命令行加 --keep-open=no（CLI 覆盖 config）" "--keep-open=no"
echo
echo "判读：若 A 的 idle 始终 false 而 B 在结尾后变 true，则插件必须先加 --keep-open=no"
