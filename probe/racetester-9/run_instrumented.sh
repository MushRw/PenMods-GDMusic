#!/bin/sh
# run_instrumented.sh —— 在【隔离副本】里给 write_file 加计时，量真机 in-situ 的 W
#
# 为什么需要：读者侧高频采样（12k reads/s）本身吃 CPU（4 核），会把 W 抬高 ——
# 那是测量装置扰动被测对象。这里换成【写者自计时】，旁边没有读者。
#
# ⚠️ 只在 /tmp/racetester-9/gdnext_audit.lua 上改，绝不碰部署件。
# ⚠️ 注入必须校验：早先正则写坏过脚本（见 instrument.pl 头注），
#    现象是 wdur.txt 不存在 + now.json 不增长 —— 会被误读成「lua 没在写」。
set -u
D=/tmp/racetester-9
SRC=/userdisk/PenMods/plugins/gdmusic/bin/gdnext.lua
SOCK=$D/gdnext-audit.sock
LUA=$D/gdnext_audit.lua
LOG=$D/mpv.log
DUR=${1:-300}

mkdir -p $D/gdmusic
sed "s|/tmp/gdmusic\"|$D/gdmusic\"|g; s|/tmp/audio_wakelocks/gdmusic.lock|$D/gdtest.lock|g" \
    "$SRC" > "$LUA"
if grep -q '/tmp/gdmusic"' "$LUA" || grep -q '/tmp/audio_wakelocks/gdmusic.lock' "$LUA"; then
  echo "ISOLATION FAILED"; exit 1
fi

# 精确注入 + 自校验（失败则整个脚本中止，不会拿坏脚本去跑）
perl $D/instrument.pl "$LUA" "$LUA.instr" 2>&1 | grep -v '^perl: warning' || exit 1
mv "$LUA.instr" "$LUA"

cat >> "$LUA" <<'EOF'

-- [AUDIT-ONLY] 等价于 gd-load 消息
play_index(tonumber((conf and conf.index) or 1) or 1)
EOF

perl $D/mkmp3.pl $D/silence.mp3 600 2>/dev/null
cat > $D/gdmusic/queue.json <<EOF
{"index":1,"source":"netease","quality":"320","autoNext":false,
 "list":[{"id":"1234567","name":"AuditTone","artist":"racetester","file":"$D/silence.mp3"}]}
EOF

rm -f "$SOCK" "$D/gdtest.lock" "$D/gdmusic/now.json" "$D/gdmusic/lua.log" $D/wdur.txt
LD_LIBRARY_PATH=/userdisk/mpv/lib \
  /userdisk/mpv/bin/mpv --no-config --no-video --ao=null --idle=yes --volume=0 \
    --input-ipc-server="$SOCK" --script="$LUA" --msg-level=all=no \
    > "$LOG" 2>&1 < /dev/null &
MPVPID=$!
echo "MPV_PID=$MPVPID"

# 先确认脚本真的跑起来了（wdur.txt 有样本才算注入有效）
i=0
while [ $i -lt 30 ]; do
  sleep 1
  [ -s $D/wdur.txt ] && { echo "INJECTION_LIVE: wdur.txt 已有 $(wc -l < $D/wdur.txt) 个样本"; break; }
  i=$((i+1))
done
if [ ! -s $D/wdur.txt ]; then
  echo "INJECTION DEAD —— now.json 与 mpv.log 如下（不得据此报数字）"
  cat $D/gdmusic/now.json 2>/dev/null; echo ""
  tail -20 "$LOG"
  kill $MPVPID 2>/dev/null
  exit 1
fi

sleep "$DUR"

echo ""
echo "=== IN-SITU W: 真 lua write_file 的 open->close 耗时（无读者扰动）==="
echo "样本数: $(wc -l < $D/wdur.txt)"
sort -n $D/wdur.txt | perl -e '
  my @v = map { chomp; $_+0 } <STDIN>;
  exit unless @v;
  my @s = sort { $a <=> $b } @v;
  my $sum = 0; $sum += $_ for @s;
  sub p { my ($a,$q)=@_; my $i=int($q*$#$a); return $a->[$i]; }
  printf("INSITU_W n=%d min=%.2f p50=%.2f p90=%.2f p95=%.2f p99=%.2f max=%.2f mean=%.2f (us)\n",
    scalar(@s), $s[0], p(\@s,0.5), p(\@s,0.9), p(\@s,0.95), p(\@s,0.99), $s[-1], $sum/@s);
'
echo "前 10 个原始样本:"; head -10 $D/wdur.txt

echo ""
echo "=== CLEANUP ==="
kill $MPVPID 2>/dev/null; sleep 1; kill -9 $MPVPID 2>/dev/null
rm -f "$SOCK" "$D/gdtest.lock"
echo "mpv killed; sock/lock removed"
ls -l "$SOCK" 2>&1
ls -ld /tmp/gdmusic 2>&1
ls -l /tmp/audio_wakelocks/
exit 0
