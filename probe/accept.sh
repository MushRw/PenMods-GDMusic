#!/bin/sh
# accept.sh —— 常驻播放器架构下的「遥控命令」验收
# 覆盖：暂停/继续、seek、音量、上一首/下一首、停止、ALSA 实际出声、播完释放锁
# （播放推进/自动续播/取流跳过 已在 gdnext-test.sh 单独验过）
IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl
SOCK=/tmp/gdmusic.sock
DIR=/tmp/gdmusic
LUA=/userdisk/PenMods/plugins/gdmusic/bin/gdnext.lua
LOCK=/tmp/audio_wakelocks/gdmusic.lock
MPVLOG=/tmp/gdmusic_mpv.log

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
now()  { cat $DIR/now.json 2>/dev/null; }
nf()   { now | sed -n "s/.*\"$1\":\([-0-9.]*\).*/\1/p" | cut -d. -f1; }
nf2()  { now | sed -n "s/.*\"$1\":\([-0-9.]*\).*/\1/p"; }     # 保留小数
sf()   { now | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }
ipc()  { LC_ALL=C $IPC $SOCK cmd "$@" >/dev/null 2>&1; }
prop() { LC_ALL=C $IPC $SOCK raw "{\"command\":[\"get_property\",\"$1\"],\"request_id\":1}" 2>/dev/null | sed -n 's/.*"data":\([^,]*\).*/\1/p'; }

echo "=== 0. 准备并开播 ==="
pkill -f "[i]nput-ipc-server=$SOCK" 2>/dev/null
rm -f $SOCK $LOCK $DIR/now.json $DIR/lua.log
mkdir -p $DIR
cat > $DIR/queue.json <<'EOF'
{"list":[{"id":"5257138","name":"曲目一","artist":"甲"},
         {"id":"509781655","name":"曲目二","artist":"乙"},
         {"id":"210049","name":"曲目三","artist":"丙"}],
 "index":1,"source":"netease","quality":"320",
 "ips":["104.18.0.1","104.17.0.1","104.19.0.1","104.20.0.1"],
 "autoNext":true,"apiBase":""}
EOF
nohup /userdisk/mpv/mpv --no-video --force-window=no --idle=yes --keep-open=no \
      --volume=80 --input-ipc-server=$SOCK --script=$LUA > $MPVLOG 2>&1 &
i=0; while [ $i -lt 40 ]; do [ -S $SOCK ] && break; i=$((i+1)); sleep 0.25; done
LC_ALL=C $IPC $SOCK cmd script-message gd-load >/dev/null 2>&1
_w=0; while [ $_w -lt 15 ]; do [ "$(sf status)" = "playing" ] && [ "$(nf dur)" -gt 0 ] 2>/dev/null && break; sleep 1; _w=$((_w+1)); done
if [ "$(sf status)" = "playing" ]; then
  pass "开播成功（index=$(nf index) dur=$(nf dur)）"
else
  fail "开播失败"; cat $DIR/lua.log 2>/dev/null; exit 1
fi
[ -f $LOCK ] && pass "唤醒锁已建立" || fail "唤醒锁未建立"

echo
echo "=== 1. 暂停 ==="
ipc set_property pause true
sleep 2
P1=$(nf2 pos); sleep 2; P2=$(nf2 pos)
echo "  pause=$(prop pause)  pos: $P1 -> $P2"
[ "$(prop pause)" = "true" ] && pass "mpv 已暂停" || fail "pause 属性未生效"
[ "$P1" = "$P2" ] && pass "暂停期间进度冻结（$P1）" || fail "暂停后进度仍在走（$P1 -> $P2）"

echo
echo "=== 2. 继续 ==="
ipc set_property pause false
sleep 3
P3=$(nf2 pos)
[ "$(prop pause)" = "false" ] && pass "mpv 已继续" || fail "继续失败"
awk -v a="$P1" -v b="$P3" 'BEGIN{exit !(b > a + 0.5)}' && pass "进度恢复增长（$P1 -> $P3）" || fail "进度未恢复（$P1 -> $P3）"

echo
echo "=== 3. seek ==="
ipc seek 100 absolute
sleep 2
S=$(nf2 pos)
echo "  seek 100 后 pos=$S"
awk -v s="$S" 'BEGIN{exit !(s > 95 && s < 115)}' && pass "seek 生效（pos=$S）" || fail "seek 未生效（pos=$S）"

echo
echo "=== 4. 音量 ==="
ipc set_property volume 45
sleep 1
V=$(prop volume)
echo "  volume=$V"
case "$V" in 45*|45) pass "音量已设为 45";; *) fail "音量=$V 期望 45";; esac
ipc set_property volume 80

echo
echo "=== 5. gd-next / gd-prev ==="
LC_ALL=C $IPC $SOCK cmd script-message gd-next >/dev/null 2>&1
_w=0; while [ $_w -lt 12 ]; do [ "$(nf index)" = "2" ] && [ "$(sf status)" = "playing" ] && break; sleep 1; _w=$((_w+1)); done
[ "$(nf index)" = "2" ] && pass "gd-next -> 第 2 首" || fail "gd-next 未生效（index=$(nf index)）"
LC_ALL=C $IPC $SOCK cmd script-message gd-prev >/dev/null 2>&1
_w=0; while [ $_w -lt 12 ]; do [ "$(nf index)" = "1" ] && [ "$(sf status)" = "playing" ] && break; sleep 1; _w=$((_w+1)); done
[ "$(nf index)" = "1" ] && pass "gd-prev -> 第 1 首" || fail "gd-prev 未生效（index=$(nf index)）"

echo
echo "=== 6. 音频输出真的到 ALSA ==="
if grep -q "AO: \[alsa\]" $MPVLOG 2>/dev/null; then
  pass "mpv 使用 ALSA 输出：$(grep 'AO: \[alsa\]' $MPVLOG | tail -1 | sed 's/^ *//')"
else
  fail "未在 mpv 日志中发现 ALSA 输出"
  grep -iE 'ao|audio' $MPVLOG 2>/dev/null | tail -5
fi

echo
echo "=== 7. gd-stop ==="
LC_ALL=C $IPC $SOCK cmd script-message gd-stop >/dev/null 2>&1
sleep 3
[ "$(sf status)" = "stopped" ] && pass "状态=stopped" || fail "状态=$(sf status)"
[ -f $LOCK ] && fail "停止后唤醒锁未释放" || pass "停止后唤醒锁已释放"
pgrep -f "[i]nput-ipc-server=$SOCK" >/dev/null && pass "播放器进程常驻（stop 不杀进程）" || fail "播放器被误杀"
echo "  /tmp/audio_wakelocks 现状: $(ls /tmp/audio_wakelocks/ 2>/dev/null | tr '\n' ' ')"

echo
echo "=== 8. 队列播完自动释放锁（短队列走到末尾）==="
cat > $DIR/queue.json <<'EOF'
{"list":[{"id":"509781655","name":"短队列","artist":"乙"}],
 "index":1,"source":"netease","quality":"320",
 "ips":["104.18.0.1","104.17.0.1"],"autoNext":true,"apiBase":""}
EOF
LC_ALL=C $IPC $SOCK cmd script-message gd-load >/dev/null 2>&1
_w=0; while [ $_w -lt 15 ]; do [ "$(sf status)" = "playing" ] && [ "$(nf dur)" -gt 0 ] 2>/dev/null && break; sleep 1; _w=$((_w+1)); done
_d=$(nf dur)
if [ -n "$_d" ] && [ "$_d" -gt 0 ] 2>/dev/null; then
  ipc seek "$(awk -v d="$_d" 'BEGIN{printf "%.2f", d-3}')" absolute
  _w=0; while [ $_w -lt 20 ]; do [ "$(sf status)" = "stopped" ] && break; sleep 1; _w=$((_w+1)); done
  [ "$(sf status)" = "stopped" ] && pass "单曲播完自动停止" || fail "未停止（$(sf status)）"
  [ -f $LOCK ] && fail "播完后锁未释放" || pass "播完后锁已释放"
  [ "$(sf reason)" = "end" ] && pass "停止原因=end（正常播完）" || echo "  [INFO] reason=$(sf reason)"
else
  fail "拿不到 duration"
fi

echo
echo "================ 结果: PASS=$PASS FAIL=$FAIL ================"
echo
echo "=== 清理 ==="
pkill -f "[i]nput-ipc-server=$SOCK" 2>/dev/null; rm -f $SOCK $LOCK
