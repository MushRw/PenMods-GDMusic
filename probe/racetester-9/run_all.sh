#!/bin/sh
# run_all.sh —— 单会话完成：隔离搭建 -> 起 mpv -> 采样真 now.json -> 收工清理
#
# ⚠️ 为什么必须全在一个 sh 里：
#    设备上 mpv 是 adb shell 的子进程，会话一结束就收 SIGHUP。
#    实测两次：单独起 mpv（即使 nohup）后 shell 退出，mpv 随即死亡，
#    now.json 停在 seq=6 不再增长 —— 会被误读成「lua 没在每秒写」。
#    把采样放在同一个会话里，mpv 全程存活。
set -u
D=/tmp/racetester-9
SRC=/userdisk/PenMods/plugins/gdmusic/bin/gdnext.lua
SOCK=$D/gdnext-audit.sock
LUA=$D/gdnext_audit.lua
LOG=$D/mpv.log

mkdir -p $D/gdmusic

# ---- 1. 隔离：只改 DIR 与 LOCK 两个字面量 ----
sed "s|/tmp/gdmusic\"|$D/gdmusic\"|g; s|/tmp/audio_wakelocks/gdmusic.lock|$D/gdtest.lock|g" \
    "$SRC" > "$LUA"
if grep -q '/tmp/gdmusic"' "$LUA" || grep -q '/tmp/audio_wakelocks/gdmusic.lock' "$LUA"; then
  echo "ISOLATION FAILED"; exit 1
fi
echo "ISOLATION ok (DIR/LOCK 已重定向到 $D)"

# 自动触发播放（等价 gd-load 走的那条路径），不动 write_file / add_timer(1)
cat >> "$LUA" <<'EOF'

-- [AUDIT-ONLY] 等价于 gd-load 消息：让 index>=1 的闸门打开
play_index(tonumber((conf and conf.index) or 1) or 1)
EOF

perl $D/mkmp3.pl $D/silence.mp3 600 2>/dev/null
cat > $D/gdmusic/queue.json <<EOF
{"index":1,"source":"netease","quality":"320","autoNext":false,
 "list":[{"id":"1234567","name":"AuditTone","artist":"racetester","file":"$D/silence.mp3"}]}
EOF

rm -f "$SOCK" "$D/gdtest.lock" "$D/gdmusic/now.json" "$D/gdmusic/lua.log"
LD_LIBRARY_PATH=/userdisk/mpv/lib \
  /userdisk/mpv/bin/mpv --no-config --no-video --ao=null --idle=yes --volume=0 \
    --input-ipc-server="$SOCK" --script="$LUA" --msg-level=all=no \
    > "$LOG" 2>&1 < /dev/null &
MPVPID=$!
echo "MPV_PID=$MPVPID"

# ---- 2. 等到 now.json 真的在动（连续两个不同 seq 才算 1Hz 定时器活了）----
i=0; last=""
while [ $i -lt 40 ]; do
  sleep 0.5
  cur=$(cat $D/gdmusic/now.json 2>/dev/null)
  seq=$(echo "$cur" | sed -n 's/.*"seq":\([0-9]*\)\..*/\1/p')
  if [ -n "$seq" ] && [ "$seq" != "$last" ] && [ -n "$last" ]; then
    echo "LUA_TIMER_ALIVE after ${i} halfsecs: seq $last -> $seq"
    break
  fi
  [ -n "$seq" ] && last=$seq
  i=$((i+1))
done
echo "now.json = $cur"

# ---- 3. 采样真 now.json ----
echo ""
echo "=== AUDIT: 真 mpv+gdnext.lua 写出的 now.json，1 Hz 写入 ==="
echo "--- (a) 满速采样 60s：每次读的坏读概率 ---"
perl $D/audit_read.pl "$D/gdmusic/now.json" 60 0 2>/dev/null
echo ""
echo "--- (b) 2ms 节拍采样 60s ---"
perl $D/audit_read.pl "$D/gdmusic/now.json" 60 2000 2>/dev/null
echo ""
echo "--- (c) 100ms 节拍采样 60s ---"
perl $D/audit_read.pl "$D/gdmusic/now.json" 60 100000 2>/dev/null

# ---- 4. 收工：kill 掉自己起的 mpv + 清 socket/锁 ----
echo ""
echo "=== CLEANUP ==="
kill $MPVPID 2>/dev/null
sleep 1
kill -9 $MPVPID 2>/dev/null
rm -f "$SOCK" "$D/gdtest.lock"
echo "mpv $MPVPID killed; sock/lock removed"
echo "--- 残留检查 ---"
ls -l "$SOCK" 2>&1
ls -l "$D/gdtest.lock" 2>&1
echo "--- 生产锁目录（应只有 VideoPlayer.lock，未被本任务改动）---"
ls -l /tmp/audio_wakelocks/
echo "--- /tmp/gdmusic 生产目录（应仍不存在）---"
ls -ld /tmp/gdmusic 2>&1
exit 0
