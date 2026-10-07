#!/bin/sh
# setup.sh —— 搭一个【完全隔离】的真 lua 运行环境（真 mpv + 真 gdnext.lua）
#
# 隔离手段（逐条对应硬约束）：
#   · DIR  /tmp/gdmusic                  -> /tmp/racetester-9/gdmusic
#   · LOCK /tmp/audio_wakelocks/gdmusic.lock -> /tmp/racetester-9/gdtest.lock
#     ⇒ 绝不触碰 /tmp/audio_wakelocks/VideoPlayer.lock
#   · --no-config  ⇒ 不加载 /userdisk/mpv/config/mpv.conf
#     （它里面写着 input-ipc-server=/tmp/mpvsocket，会撞用户正在用的播放器）
#   · --input-ipc-server=/tmp/racetester-9/gdnext-audit.sock（独立 socket）
#   · --ao=null    ⇒ 不打开真实音频设备，不跟 AudioDaemon 抢
#   · 用真二进制 /userdisk/mpv/bin/mpv（/userdisk/mpv/mpv 是 wrapper，
#     它会写 VideoPlayer.lock —— 明确避开）
set -e
D=/tmp/racetester-9
SRC=/userdisk/PenMods/plugins/gdmusic/bin/gdnext.lua
SOCK=$D/gdnext-audit.sock
LUA=$D/gdnext_audit.lua
LOG=$D/mpv.log

mkdir -p $D/gdmusic

# 1) 路径隔离：只改 DIR 与 LOCK 两个字面量
sed "s|/tmp/gdmusic\"|$D/gdmusic\"|g; s|/tmp/audio_wakelocks/gdmusic.lock|$D/gdtest.lock|g" \
    "$SRC" > "$LUA"

# 2) 断言：改后的路径确实全部落在隔离区，且没有残留生产路径
BAD=0
grep -n '/tmp/gdmusic"' "$LUA" && BAD=1
grep -n '/tmp/audio_wakelocks/gdmusic.lock' "$LUA" && BAD=1
[ $BAD -eq 0 ] || { echo "ISOLATION FAILED"; exit 1; }
echo "ISOLATION ok: DIR/LOCK 均已重定向"
grep -n 'local DIR\|local LOCK\|local NFILE' "$LUA"

# 3) 自动触发播放（等价于 QML 发 gd-load 走的同一条路径：
#    register_msg("gd-load") -> play_index(tonumber(conf.index))）。
#    不改 write_file / 不动 add_timer(1)。
cat >> "$LUA" <<'EOF'

-- [AUDIT-ONLY] 隔离副本自动触发播放；等价于 gd-load 消息走的那条路径
play_index(tonumber((conf and conf.index) or 1) or 1)
EOF
echo "AUDIT trigger appended"

# 4) 生成离线可解码音频 + queue.json（走 song.file 分支，完全不碰网络）
#    ⚠️ 真机这份 mpv 的 libavcodec 缺 pcm_s16le 解码器（WAV 必失败，实测），
#       所以用 mp3。
perl $D/mkmp3.pl $D/silence.mp3 600 2>/dev/null
cat > $D/gdmusic/queue.json <<EOF
{"index":1,"source":"netease","quality":"320","autoNext":false,
 "list":[{"id":"1234567","name":"AuditTone","artist":"racetester","file":"$D/silence.mp3"}]}
EOF

# 5) 起 mpv
#    ⚠️ 必须 nohup + </dev/null：否则 adb shell 会话一结束就发 SIGHUP 把 mpv 收走
#    （实测：不加时 mpv 只活了 2 秒，now.json 停在 seq=6 不再增长，
#      采样 60s 看到 distinct_seq=1 —— 会被误读成「lua 没在每秒写」）
rm -f "$SOCK" "$D/gdtest.lock" "$D/gdmusic/now.json" "$D/gdmusic/lua.log"
LD_LIBRARY_PATH=/userdisk/mpv/lib \
  nohup /userdisk/mpv/bin/mpv --no-config --no-video --ao=null --idle=yes --volume=0 \
    --input-ipc-server="$SOCK" --script="$LUA" --msg-level=all=no \
    > "$LOG" 2>&1 < /dev/null &
echo "MPV_PID=$!"
echo "$!" > $D/mpv.pid
sleep 3
echo "--- mpv alive? ---"
ps w 2>/dev/null | grep '[g]dnext-audit.sock' || echo "(未匹配到)"
echo "--- socket ---"
ls -l "$SOCK" 2>&1
echo "--- now.json ---"
ls -l $D/gdmusic/now.json 2>&1
cat $D/gdmusic/now.json 2>/dev/null; echo ""
echo "--- lua.log ---"
cat $D/gdmusic/lua.log 2>/dev/null | tail -20
echo "--- mpv.log tail ---"
tail -20 "$LOG" 2>/dev/null
echo "--- VideoPlayer.lock 未被动过 ---"
ls -l /tmp/audio_wakelocks/
