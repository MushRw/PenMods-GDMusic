#!/bin/sh
# 端到端：把 QML 生成的命令**原样**在设备上执行，验证「插件 → 常驻播放器」整条链路。
# 这是最贴近真实运行的一层验证：命令不是我手写的，是 qmlscene 跑 main.qml 真跑出来的。
IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl
SOCK=/tmp/gdmusic.sock
DIR=/tmp/gdmusic
LOCK=/tmp/audio_wakelocks/gdmusic.lock

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
now()  { cat $DIR/now.json 2>/dev/null; }
nf()   { now | sed -n "s/.*\"$1\":\([-0-9.]*\).*/\1/p" | cut -d. -f1; }
sf()   { now | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }

echo "=== 0. 清场 ==="
pkill -f "[i]nput-ipc-server=$SOCK" 2>/dev/null
rm -f $SOCK $LOCK $DIR/queue.json $DIR/now.json $DIR/lua.log
mkdir -p $DIR

echo
echo "=== 1. 在设备上跑 qmlscene，取出 main.qml 真实生成的命令 ==="
OUT=$(cd /tmp && QT_QPA_PLATFORM=offscreen timeout 40 /usr/bin/qmlscene /tmp/qmlcheck.qml 2>&1)
CMD_Q=$(echo "$OUT" | sed -n 's/^qml: CHK writeQ=//p')
CMD_P=$(echo "$OUT" | sed -n 's/^qml: CHK playerStart=//p')
CMD_M=$(echo "$OUT" | sed -n 's/^qml: CHK msgLoad=//p')
[ -z "$CMD_Q" ] && { echo "  取不到 writeQ 命令"; echo "$OUT" | head -20; exit 1; }
echo "  写队列命令 前120字符: $(echo "$CMD_Q" | cut -c1-120)…"
echo "  启动播放器命令 前100字符: $(echo "$CMD_P" | cut -c1-100)…"
echo "  载入命令: $(echo "$CMD_M" | cut -c1-120)…"

echo
echo "=== 2. 原样执行「写队列」命令 ==="
eval "$CMD_Q"
echo "  queue.json 内容:"
cat $DIR/queue.json; echo
# 校验中文与单引号都活着（这正是最容易在转义上翻车的地方）
if grep -q "Don't Stop" $DIR/queue.json && grep -q "中文歌名" $DIR/queue.json; then
  pass "含单引号与中文的歌名已正确落盘"
else
  fail "歌名被 shell 转义破坏"
fi
JQ_IDX=$(sed -n 's/.*"index":\([0-9]*\).*/\1/p' $DIR/queue.json)
[ "$JQ_IDX" = "1" ] && pass "index 已按 lua 约定从 1 起（index=$JQ_IDX）" || fail "index=$JQ_IDX 期望 1"

echo
echo "=== 3. 原样执行「启动常驻播放器」命令 ==="
eval "$CMD_P"
i=0; while [ $i -lt 40 ]; do [ -S $SOCK ] && break; i=$((i+1)); sleep 0.25; done
[ -S $SOCK ] && pass "播放器 socket 就绪" || fail "socket 未就绪"
sleep 2
echo "  lua 日志头部: $(head -2 $DIR/lua.log 2>/dev/null | tr '\n' '|')"

echo
echo "=== 4. 原样执行「载入」命令 ==="
echo "  命令本身: $(echo "$CMD_M" | sed 's/.*cmd //')"
eval "$CMD_M"
_w=0
while [ $_w -lt 15 ]; do
  [ "$(sf status)" = "playing" ] && [ "$(nf dur)" -gt 0 ] 2>/dev/null && break
  sleep 1; _w=$((_w+1))
done
echo "  now.json: $(now)"
[ "$(sf status)" = "playing" ] && pass "第 1 首已播放" || fail "未进入 playing（status=$(sf status)）"
[ -f $LOCK ] && pass "唤醒锁已建立(内容=$(cat $LOCK))" || fail "唤醒锁未建立"

echo
echo "=== 5. 播完自动续播第 2 首（lua 自主推进，QML 只跟随）==="
_d=$(nf dur)
if [ -n "$_d" ] && [ "$_d" -gt 0 ] 2>/dev/null; then
  _t=$(awk -v d="$_d" 'BEGIN{printf "%.2f", d-4}')
  LC_ALL=C $IPC $SOCK cmd seek "$_t" absolute >/dev/null 2>&1
  echo "  seek $_t/$_d"
  _w=0
  while [ $_w -lt 15 ]; do
    sleep 1; _w=$((_w+1))
    [ "$(nf index)" = "2" ] && [ "$(sf status)" = "playing" ] && break
  done
  [ "$(nf index)" = "2" ] && pass "自动续播到第 2 首（now.json index=$(nf index)）" || fail "未续播（index=$(nf index)）"
else
  fail "拿不到 duration"
fi

echo
echo "=== 6. 队列播完 → 停播 + 释放唤醒锁 ==="
_d=$(nf dur)
if [ -n "$_d" ] && [ "$_d" -gt 0 ] 2>/dev/null; then
  _t=$(awk -v d="$_d" 'BEGIN{printf "%.2f", d-3}')
  LC_ALL=C $IPC $SOCK cmd seek "$_t" absolute >/dev/null 2>&1
  _w=0
  while [ $_w -lt 20 ]; do
    sleep 1; _w=$((_w+1))
    [ "$(sf status)" = "stopped" ] && break
  done
  echo "  now.json: $(now)"
  [ "$(sf status)" = "stopped" ] && pass "队列播完已停播" || fail "未停播(=$(sf status))"
  [ -f $LOCK ] && fail "锁未释放" || pass "唤醒锁已释放"
fi

echo
echo "=== 7. 模拟「关闭插件」：QML 销毁后播放器应当继续活着 ==="
# 真实场景里 QML 销毁不会再碰播放器；这里等价于「什么都不做，等几秒看它是否还在」
PID1=$(pgrep -f "[i]nput-ipc-server=$SOCK" | head -1)
sleep 4
PID2=$(pgrep -f "[i]nput-ipc-server=$SOCK" | head -1)
[ -n "$PID2" ] && [ "$PID1" = "$PID2" ] && pass "播放器进程未被销毁（pid=$PID2 保持不变）" || fail "播放器不见了或换 pid"
# 再开播一首，确认此刻还能被正常遥控（等价于重进插件）
LC_ALL=C $IPC $SOCK cmd script-message gd-load >/dev/null 2>&1
_w=0
while [ $_w -lt 15 ]; do
  [ "$(sf status)" = "playing" ] && break
  sleep 1; _w=$((_w+1))
done
[ "$(sf status)" = "playing" ] && pass "停播后仍可重新开播（模拟重进插件）" || fail "重开播失败"

echo
echo "=== 8. 收尾：真正停掉 ==="
LC_ALL=C $IPC $SOCK cmd script-message gd-stop >/dev/null 2>&1
sleep 2
[ -f $LOCK ] && fail "gd-stop 后锁仍在" || pass "gd-stop 后锁已释放"
pkill -f "[i]nput-ipc-server=$SOCK" 2>/dev/null; rm -f $SOCK $LOCK

echo
echo "================ 结果: PASS=$PASS FAIL=$FAIL ================"
echo "================ gdnext 日志 ================"
cat $DIR/lua.log 2>/dev/null
echo "============================================="
