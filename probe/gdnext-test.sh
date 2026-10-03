#!/bin/sh
# 单独验证 gdnext.lua（常驻播放器内核）——不涉及 QML
# 编排要点：每次动作前先等状态稳定、dur 有效，否则会撞上正在进行的取流（上一轮就吃过这个亏）
IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl
SOCK=/tmp/gdmusic.sock
DIR=/tmp/gdmusic
LUA=/userdisk/PenMods/plugins/gdmusic/bin/gdnext.lua
LOCK=/tmp/audio_wakelocks/gdmusic.lock

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
now()  { cat $DIR/now.json 2>/dev/null; }
nf()   { now | sed -n "s/.*\"$1\":\([-0-9.]*\).*/\1/p" | cut -d. -f1; }
sf()   { now | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }
msg()  { LC_ALL=C $IPC $SOCK cmd script-message "$1" 2>&1 | head -1; }

# 等到 index=$1 且 status=playing，最多 $2 轮（每轮 1s）
wait_playing() {
  _w=0
  while [ $_w -lt "$2" ]; do
    [ "$(nf index)" = "$1" ] && [ "$(sf status)" = "playing" ] && [ "$(nf dur)" -gt 0 ] 2>/dev/null && return 0
    sleep 1; _w=$((_w+1))
  done
  return 1
}
# 等 dur 有效**且已真正开始播**（pos>1）再跳到结尾。
# 网络流的 demuxer 未就绪时 mpv 会直接丢弃 seek（上一轮就踩到这个假失败）。
seekend() {
  _w=0
  while [ $_w -lt 25 ]; do
    _d=$(nf dur); _p=$(nf pos)
    [ -n "$_d" ] && [ "$_d" -gt 0 ] 2>/dev/null \
      && [ -n "$_p" ] && [ "$_p" -gt 1 ] 2>/dev/null && break
    sleep 1; _w=$((_w+1))
  done
  [ -z "$_d" ] || [ "$_d" -le 0 ] 2>/dev/null && return 1
  _t=$(awk -v d="$_d" -v k="$1" 'BEGIN{printf "%.2f", d-k}')
  LC_ALL=C $IPC $SOCK cmd seek "$_t" absolute >/dev/null 2>&1
  echo "     (seek ${_t}/${_d})"
  return 0
}
snap() { echo "     index=$(nf index) status=$(sf status) dur=$(nf dur) pos=$(nf pos) reason=$(sf reason) lock=$([ -f $LOCK ] && echo 有 || echo 无)"; }

pkill -f "[i]nput-ipc-server=$SOCK" 2>/dev/null
rm -f $SOCK $LOCK $DIR/now.json $DIR/lua.log
mkdir -p $DIR

echo "=== 0. 队列：好/好/好/坏 ==="
cat > $DIR/queue.json <<'EOF'
{"list":[{"id":"5257138","name":"曲目一","artist":"甲"},
         {"id":"509781655","name":"曲目二","artist":"乙"},
         {"id":"210049","name":"曲目三","artist":"丙"},
         {"id":"99999999999999","name":"坏曲目","artist":"丁"}],
 "index":1,"source":"netease","quality":"320",
 "ips":["104.18.0.1","104.17.0.1","104.19.0.1","104.20.0.1"],
 "autoNext":true,"apiBase":""}
EOF

echo
echo "=== 1. 启动 mpv（无 url，纯 idle + 挂 lua）==="
nohup /userdisk/mpv/mpv --no-video --force-window=no --keep-open=no --idle=yes \
      --volume=80 --input-ipc-server=$SOCK --script=$LUA \
      >/tmp/gdnext_mpv.log 2>&1 &
i=0; while [ $i -lt 40 ]; do [ -S $SOCK ] && break; i=$((i+1)); sleep 0.25; done
[ -S $SOCK ] && pass "socket 就绪" || fail "socket 未就绪"
sleep 1

echo
echo "=== 2. gd-load（无参，播 queue.json 的 index=1）==="
echo "   返回: $(msg gd-load)"
if wait_playing 1 12; then pass "第 1 首进入 playing"; else fail "第 1 首未播放"; snap; fi
[ -f $LOCK ] && pass "唤醒锁已建立(内容=$(cat $LOCK))" || fail "唤醒锁未建立"

echo
echo "=== 3. 播完第 1 首 -> 自动续播第 2 首 ==="
if seekend 4; then
  if wait_playing 2 12; then pass "自动续播到第 2 首"; else fail "未续播到第 2 首"; snap; fi
else fail "第1首拿不到 duration"; fi

echo
echo "=== 4. 播完第 2 首 -> 自动续播第 3 首 ==="
if seekend 4; then
  if wait_playing 3 12; then pass "自动续播到第 3 首"; else fail "未续播到第 3 首"; snap; fi
else fail "第2首拿不到 duration"; fi

echo
echo "=== 5. 遥控 gd-prev ==="
echo "   返回: $(msg gd-prev)"
if wait_playing 2 10; then pass "gd-prev 回到第 2 首"; else fail "gd-prev 未生效"; snap; fi

echo
echo "=== 6. 遥控 gd-next ==="
echo "   返回: $(msg gd-next)"
if wait_playing 3 10; then pass "gd-next 前进到第 3 首"; else fail "gd-next 未生效"; snap; fi

echo
echo "=== 7. 播完第 3 首 -> 跳过坏的第 4 首 -> 队列结束，停播并释放锁 ==="
if seekend 4; then
  _w=0
  while [ $_w -lt 20 ]; do
    sleep 1; _w=$((_w+1))
    [ "$(sf status)" = "stopped" ] && break
  done
  snap
fi
[ "$(sf status)" = "stopped" ] && pass "队列播完已停播" || fail "未停播(状态=$(sf status))"
[ -f $LOCK ] && fail "播完后锁未释放" || pass "播完后唤醒锁已释放"
[ "$(sf reason)" = "end" ] && pass "停止原因=end（正常播完，非取流失败）" || echo "  [INFO] reason=$(sf reason)"

echo
echo "=== 8. 停播后重播（模拟重进插件）==="
cat > $DIR/queue.json <<'EOF'
{"list":[{"id":"5257138","name":"重播曲","artist":"甲"}],
 "index":1,"source":"netease","quality":"320",
 "ips":["104.18.0.1","104.17.0.1"],"autoNext":true,"apiBase":""}
EOF
echo "   返回: $(msg gd-load)"
if wait_playing 1 12; then pass "停播后可重新开播"; else fail "重播失败"; snap; fi

echo
echo "=== 9. gd-stop（用户主动停止）==="
echo "   返回: $(msg gd-stop)"
sleep 2
[ -f $LOCK ] && fail "gd-stop 后锁仍在" || pass "gd-stop 后锁已释放"
[ "$(sf status)" = "stopped" ] && pass "状态=stopped（未被每秒定时器覆盖）" || fail "状态=$(sf status)"

echo
echo "================ 结果: PASS=$PASS FAIL=$FAIL ================"
echo "================ gdnext 日志 ================"
cat $DIR/lua.log 2>/dev/null
echo "============================================="
echo "--- mpv 侧 lua 报错（应为空）---"
grep -iE 'lua.*error|gdnext.*error' /tmp/gdnext_mpv.log 2>/dev/null | head -10

echo
echo "=== 清理 ==="
pkill -f "[i]nput-ipc-server=$SOCK" 2>/dev/null; rm -f $SOCK $LOCK; true
