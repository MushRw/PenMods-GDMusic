#!/bin/sh
# run_phase.sh —— 单会话：起真 mpv+lua，跑 phase.pl 直接量每次写的坏窗口与相位漂移
set -u
D=/tmp/racetester-9
SRC=/userdisk/PenMods/plugins/gdmusic/bin/gdnext.lua
SOCK=$D/gdnext-audit.sock
LUA=$D/gdnext_audit.lua
LOG=$D/mpv.log

mkdir -p $D/gdmusic
sed "s|/tmp/gdmusic\"|$D/gdmusic\"|g; s|/tmp/audio_wakelocks/gdmusic.lock|$D/gdtest.lock|g" \
    "$SRC" > "$LUA"
if grep -q '/tmp/gdmusic"' "$LUA" || grep -q '/tmp/audio_wakelocks/gdmusic.lock' "$LUA"; then
  echo "ISOLATION FAILED"; exit 1
fi
cat >> "$LUA" <<'EOF'

-- [AUDIT-ONLY] 等价于 gd-load 消息
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

i=0; last=""
while [ $i -lt 40 ]; do
  sleep 0.5
  cur=$(cat $D/gdmusic/now.json 2>/dev/null)
  seq=$(echo "$cur" | sed -n 's/.*"seq":\([0-9]*\)\..*/\1/p')
  if [ -n "$seq" ] && [ "$seq" != "$last" ] && [ -n "$last" ]; then
    echo "LUA_TIMER_ALIVE: seq $last -> $seq"; break
  fi
  [ -n "$seq" ] && last=$seq
  i=$((i+1))
done

echo ""
echo "=== PHASE: 真 lua now.json，180s 高频采样 ==="
perl $D/phase.pl "$D/gdmusic/now.json" 180 2>/dev/null

echo ""
echo "=== 写入节奏原始证据（seq 时间线，取 12 秒窗口）==="
perl $D/audit_read.pl "$D/gdmusic/now.json" 12 0 2>/dev/null

echo ""
echo "=== CLEANUP ==="
kill $MPVPID 2>/dev/null; sleep 1; kill -9 $MPVPID 2>/dev/null
rm -f "$SOCK" "$D/gdtest.lock"
echo "mpv killed, sock/lock removed"
ls -l "$SOCK" 2>&1
ls -ld /tmp/gdmusic 2>&1
ls -l /tmp/audio_wakelocks/
exit 0
