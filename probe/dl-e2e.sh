#!/bin/sh
# GD音乐「下载功能」端到端实测（在设备上跑，全部断言借鉴 §5 的思路）
#
#   1) 取真实播放地址（线上 API）
#   2) 用插件 buildDownloadCmd() 生成的那条命令原样下载
#   3) 校验：.part 已消失、最终文件非空、状态文件内容为 ok:<size>
#   4) 把本地文件塞进 queue.json，用常驻播放器播 —— 验 lua 的「本地直读」分支，
#      判据用 time-pos 是否随时间推进（唯一可信的"真的在播"证据）
#
# 用法: adb push probe/dl-e2e.sh /tmp/ && adb shell "sh /tmp/dl-e2e.sh"

HOST=music-api.gdstudio.xyz
DIR=/userdisk/Music/GDMusic
STDIR=/tmp/gdmusic/dl
ID=5257138
SRC=netease
BR=320
SOCK=/tmp/gdmusic.sock
IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl
LUA=/userdisk/PenMods/plugins/gdmusic/bin/gdnext.lua

pass=0; failn=0
ok()   { pass=$((pass+1)); echo "  PASS  $1"; }
bad()  { failn=$((failn+1)); echo "  FAIL  $1"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (期望 $3, 实际 $2)"; fi; }

mkdir -p "$DIR" "$STDIR"

echo "=== 1) 取播放地址 ==="
URL=""
for IP in 104.18.0.1 104.17.0.1 ""; do
    R=""
    if [ -n "$IP" ]; then
        R=$(curl -s --max-time 10 -A 'Mozilla/5.0' \
            --resolve "$HOST:443:$IP" "https://$HOST/api.php?types=url&source=$SRC&id=$ID&br=$BR")
    else
        R=$(curl -s --max-time 10 -A 'Mozilla/5.0' \
            "https://$HOST/api.php?types=url&source=$SRC&id=$ID&br=$BR")
    fi
    U=$(printf '%s' "$R" | sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    if [ -n "$U" ]; then URL="$U"; echo "  拿到地址(IP=${IP:-默认}): ${U%"${U#*://}"}"; break; fi
done
if [ -n "$URL" ]; then ok "取到播放地址"; else bad "取不到播放地址"; fi

echo
echo "=== 2) 用插件生成的命令下载 ==="
# 与 main.qml buildDownloadCmd() 完全一致的一段（含 .part -> mv、-s 校验、状态文件）
FILE="$DIR/E2E测试-本地下载.mp3"
ST="$STDIR/e2e.st"
rm -f "$FILE" "$FILE.part" "$ST"
sh -c "if curl -sL --max-time 900 --connect-timeout 15 -A 'Mozilla/5.0' -o '$FILE.part' '$URL'; then
         if [ -s '$FILE.part' ]; then
           mv '$FILE.part' '$FILE'
           printf 'ok:%s' \"\$(stat -c%s '$FILE')\" > '$ST'
         else rm -f '$FILE.part'; printf 'fail:下载为空' > '$ST'; fi
       else rm -f '$FILE.part'; printf 'fail:网络中断' > '$ST'; fi"

echo
echo "=== 3) 落盘校验 ==="
chk ".part 临时文件已清理" "$([ ! -e "$FILE.part" ] && echo yes)" "yes"
chk "最终 mp3 存在"        "$([ -s "$FILE" ] && echo yes)" "yes"
STC=$(cat "$ST" 2>/dev/null)
case "$STC" in ok:*) ok "状态文件内容正确 ($STC)";; *) bad "状态文件内容异常 ($STC)";; esac
SZ=$(stat -c%s "$FILE" 2>/dev/null || echo 0)
if [ "$SZ" -gt 102400 ]; then ok "文件大小合理 ($SZ 字节)"; else bad "文件过小 ($SZ 字节)"; fi
chk "文件后缀为 .mp3" "$(printf '%s' "$FILE" | sed 's/.*\.//')" "mp3"

echo
echo "=== 4) 写 index.json（模拟插件的 addToLocalIndex）==="
cat > "$DIR/index.json" <<EOF
[{"id":"$ID","source":"$SRC","name":"E2E测试","artist":"本地下载","file":"$FILE","size":$SZ,"ts":1}]
EOF
chk "index.json 可解析" "$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "$DIR/index.json")" "$ID"

echo
echo "=== 5) 本地文件播放（验 lua 的直读分支）==="
pkill -f '[i]nput-ipc-server=/tmp/gdmusic.sock' 2>/dev/null
rm -f "$SOCK" /tmp/gdmusic/now.json
mkdir -p /tmp/gdmusic
# 队列里这项只有 file，没有在线地址 —— 若 lua 没走本地分支就会播放失败
cat > /tmp/gdmusic/queue.json <<EOF
{"list":[{"id":"$ID","name":"E2E测试","artist":"本地下载","file":"$FILE"}],
 "index":1,"source":"$SRC","quality":"$BR","ips":["104.18.0.1"],"autoNext":true,"apiBase":""}
EOF
nohup /userdisk/mpv/mpv --no-video --force-window=no --idle=yes --keep-open=no \
      --volume=60 --input-ipc-server="$SOCK" --script="$LUA" \
      > /tmp/gdmusic_mpv_e2e.log 2>&1 &

i=0
while [ "$i" -lt 60 ]; do [ -S "$SOCK" ] && break; i=$((i+1)); sleep 0.25; done
[ -S "$SOCK" ] && ok "mpv socket 就绪" || bad "mpv socket 未就绪"

perl "$IPC" "$SOCK" cmd script-message gd-load >/dev/null 2>&1
sleep 6

P1=$(perl "$IPC" "$SOCK" status 2>/dev/null | cut -d'|' -f2)
sleep 3
P2=$(perl "$IPC" "$SOCK" status 2>/dev/null | cut -d'|' -f2)
STT=$(cat /tmp/gdmusic/now.json 2>/dev/null | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
echo "  now.json status=$STT"
chk "状态已变成 playing" "$STT" "playing"
if [ -n "$P1" ] && [ -n "$P2" ] && [ "$P2" != "$P1" ]; then ok "播放位置在推进 ($P1 -> $P2)"; else bad "播放位置未推进 ($P1 -> $P2)"; fi
chk "持有音频唤醒锁" "$([ -f /tmp/audio_wakelocks/gdmusic.lock ] && echo yes)" "yes"

echo
echo "=== 6) 清理 ==="
pkill -f '[i]nput-ipc-server=/tmp/gdmusic.sock' 2>/dev/null
sleep 2
chk "停播后唤醒锁已释放" "$([ ! -f /tmp/audio_wakelocks/gdmusic.lock ] && echo yes)" "yes"
rm -f "$FILE" "$DIR/index.json"
echo
echo "=========== 合计 PASS=$pass FAIL=$failn ==========="
[ "$failn" -eq 0 ] || exit 1
