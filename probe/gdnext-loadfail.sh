#!/bin/sh
# 真机验证 gdnext.lua 的两条「播放推进」缺陷（都会表现为"播着播着就没动静了"）：
#
# ① P1-1：loadfile 失败（switching=true）时必须顺延，不能被吞掉。
# ② (2026-10-06 真机时顺带挖到) loading 标志在本地文件分支永远不复位，
#    于是「播完一首已下载的歌之后不会自动播下一首」—— 场景A 的第一跳就踩到这里，
#    所以本脚本同时守住这两条。
#
# 构造方式与 gdnext-test.sh 不同：全程用**本地文件**，完全不碰网络 ——
#   · 好曲目：/userdisk/Music 下的真 mp3（song.file 走 gdnext 的本地直连分支）
#   · 坏曲目：存在、但内容根本不是音频的文件。
#     io.open 会成功 ⇒ 不会被「本地文件已丢失」那条分支提前拦下，
#     但 mpv loadfile 必然失败 ⇒ end-file{reason=error} + switching=true，
#     正是修复前被无条件 return 吞掉的那条路径。
#     线上等价物是「GD 返回的直链 403/404/超时」—— 拿到 URL 但流打不开。
#
# 线上要复现这条路径得等 GD 直链过期且刚好被撞上，不可控；本地构造每次必现。
#
# 用法：
#   adb push probe/gdnext-loadfail.sh /tmp/
#   adb shell "sh /tmp/gdnext-loadfail.sh"

IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl
LUA=/userdisk/PenMods/plugins/gdmusic/bin/gdnext.lua
SOCK=/tmp/gdnext-lf.sock          # 刻意区别于常驻的 /tmp/gdmusic.sock
DIR=/tmp/gdmusic                  # gdnext.lua 里写死，借用同一个worker目录
LF=/tmp/gdmusic-lf
LOCK=/tmp/audio_wakelocks/gdmusic.lock

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
nf()   { cat $DIR/now.json 2>/dev/null | sed -n "s/.*\"$1\":\([-0-9.]*\).*/\1/p" | cut -d. -f1; }
sf()   { cat $DIR/now.json 2>/dev/null | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }
msg()  { LC_ALL=C $IPC $SOCK cmd script-message "$1" 2>&1 | head -1; }
snap() { echo "     index=$(nf index) status=$(sf status) dur=$(nf dur) pos=$(nf pos) reason=$(sf reason)"; }

# 等到 index=$1 且 status=playing
wait_playing() {
  _w=0
  while [ $_w -lt "$2" ]; do
    [ "$(nf index)" = "$1" ] && [ "$(sf status)" = "playing" ] && return 0
    sleep 1; _w=$((_w+1))
  done
  return 1
}
# 等本地文件的 duration 出来（比网络流快得多）
wait_stopped() {
  _w=0
  while [ $_w -lt "$2" ]; do
    [ "$(sf status)" = "stopped" ] && return 0
    sleep 1; _w=$((_w+1))
  done
  return 1
}

echo "=== 0. 准备素材 ==="
mkdir -p $LF $DIR /tmp/audio_wakelocks
rm -f $DIR/lua.log $DIR/now.json
# 两首"好"曲目：
#   第 1 首用 ffmpeg 现造的 2 秒正弦 ⇨ 2 秒就自然播完，触发【连播】进坏曲目。
#   （原先取自 /userdisk/Music 的真歌：这套 headless 环境下 alsa 播到最后会卡在
#     00:03:44/00:03:45 不再前进 —— 尾部 drain 阻塞，eof 不来 ⇒ 用 seek 会假失败。）
mkdir -p $LF
ffmpeg -hide_banner -loglevel error -f lavfi -i 'sine=frequency=440:duration=2' \
       -y $LF/short.mp3 2>/dev/null
GOOD1=$LF/short.mp3
GOOD2=$(ls /userdisk/Music/LX-Pen-ch/*.mp3 2>/dev/null | head -1)
[ -s "$GOOD1" ] && pass "短音频素材就绪（2 秒，会自动播完）" || fail "ffmpeg 造不出短音频"
[ -n "$GOOD2" ] && pass "找到素材 $GOOD2" || fail "设备上没有可用的 mp3，无法离线构造"
# 坏曲目：存在、可读，但内容不是任何可解封装的格式
printf 'this is definitely not an mp3\n' > $LF/broken1.mp3
printf 'neither is this one\n'          > $LF/broken2.mp3
printf 'nor this\n'                     > $LF/broken3.mp3
printf 'and not this\n'                 > $LF/broken4.mp3
[ -s $LF/broken1.mp3 ] && pass "已造假文件（存在且非空 ⇒ io.open 必成功）" || fail "假文件没造出来"

pkill -f "[i]nput-ipc-server=$SOCK" 2>/dev/null; rm -f $SOCK $LOCK; sleep 1

echo
echo "=== 1. 起 mpv（idle + 挂修改后的 gdnext.lua）==="
nohup /userdisk/mpv/mpv --no-video --force-window=no --keep-open=no --idle=yes \
      --volume=50 --input-ipc-server=$SOCK --script=$LUA \
      >/tmp/gdnext_lf.log 2>&1 &
i=0; while [ $i -lt 40 ]; do [ -S $SOCK ] && break; i=$((i+1)); sleep 0.25; done
[ -S $SOCK ] && pass "socket 就绪" || { fail "socket 未就绪"; exit 1; }
sleep 1

echo
echo "=== 2. 场景A：好 → 坏 → 好，坏的那首必须自动顺延 ==="
cat > $DIR/queue.json <<EOF
{"list":[{"id":"g1","name":"好歌1","artist":"本地","file":"$GOOD1"},
         {"id":"b1","name":"坏歌","artist":"本地","file":"$LF/broken1.mp3"},
         {"id":"g2","name":"好歌2","artist":"本地","file":"$GOOD2"}],
 "index":1,"source":"netease","quality":"320","ips":[],"autoNext":true,"apiBase":""}
EOF
echo "   返回: $(msg gd-load)"
if wait_playing 1 15; then pass "第 1 首（2 秒短音频）正常开播"; else fail "第 1 首没播起来"; snap; fi

# ⭐ 核心断言：第 1 首自然播完 → 连播第 2 首（坏）→ 打不开 → 必须顺延到第 3 首。
#    修复前会永久卡在 index=2：switching 被无条件 return 吞掉，没人再推进。
echo "   等待第 1 首播完并跨过坏曲目..."
if wait_playing 3 25; then
  pass "坏曲目后自动顺延到第 3 首（修复前会卡死在第 2 首）"
else
  fail "没有顺延 —— 卡在 index=$(nf index) status=$(sf status)"
  snap
fi
grep -q "本次 loadfile 未播成" $DIR/lua.log \
  && pass "lua.log 留下了走的是新分支的证据" || fail "lua.log 里找不到新分支的日志"
grep "本次 loadfile 未播成" $DIR/lua.log 2>/dev/null | tail -1

echo
echo "=== 3. 场景B：坏歌连成一串时有界退出，且每首都真的被尝试过 ==="
pkill -f "[i]nput-ipc-server=$SOCK" 2>/dev/null; rm -f $SOCK $LOCK $DIR/lua.log $DIR/now.json; sleep 1
nohup /userdisk/mpv/mpv --no-video --force-window=no --keep-open=no --idle=yes \
      --volume=50 --input-ipc-server=$SOCK --script=$LUA \
      >/tmp/gdnext_lf.log 2>&1 &
i=0; while [ $i -lt 40 ]; do [ -S $SOCK ] && break; i=$((i+1)); sleep 0.25; done
[ -S $SOCK ] && pass "mpv 重新起来" || fail "mpv 没起来"
sleep 1
cat > $DIR/queue.json <<EOF
{"list":[{"id":"b1","name":"坏1","artist":"本地","file":"$LF/broken1.mp3"},
         {"id":"b2","name":"坏2","artist":"本地","file":"$LF/broken2.mp3"},
         {"id":"b3","name":"坏3","artist":"本地","file":"$LF/broken3.mp3"},
         {"id":"b4","name":"坏4","artist":"本地","file":"$LF/broken4.mp3"}],
 "index":1,"source":"netease","quality":"320","ips":[],"autoNext":true,"apiBase":""}
EOF
echo "   返回: $(msg gd-load)"
sleep 8
# 📌 已知事实（与本次修复无关，是本设备 mpv 的既有行为，生产启动参数正是同一套
#    --idle=yes --keep-open=no，见 MediaBridge.qml 的 buildEnsurePlayerCmd）：
#    mpv 在 idle 模式下 loadfile 失败会走向 "Exiting... (Quit)"。所以断言写的是
#    「队列确实被逐首推进过、最后有界收尾」，不去期待唤醒锁状态那一套。
_idx=$(grep -c "play_index: i=" $DIR/lua.log)
if [ "$_idx" -ge 4 ] 2>/dev/null; then
  pass "4 首坏歌逐首都真的尝试过了（共 $_idx 次 play_index）"
else
  fail "没逐首推进，只试了 $_idx 首"; snap
fi
grep -q "stop: reason=end 播放结束" $DIR/lua.log \
  && pass "越过队尾后有界收尾（release_and_stop end），没有无限转圈" \
  || fail "没能有界收尾（队尾处理缺失）"
_n=$(grep -c "按坏歌顺延" $DIR/lua.log)
echo "     顺延次数: $_n（4 首全坏 ⇒ 应为 4 次：前 3 首各顺延一次 + 第 4 首越过队尾）"
[ "$_n" -ge 3 ] 2>/dev/null && pass "连续失败时持续顺延，没有中途静默卡死" || fail "顺延次数偏少：$_n"

echo
echo "================ 结果: PASS=$PASS FAIL=$FAIL ================"
echo "================ lua.log（场景B）================"
cat $DIR/lua.log 2>/dev/null
echo "================================================"
echo "--- mpv 侧报错节选 ---"
grep -iE 'error|failed' /tmp/gdnext_lf.log 2>/dev/null | head -6

echo
echo "=== 清理 ==="
pkill -f "[i]nput-ipc-server=$SOCK" 2>/dev/null; rm -f $SOCK $LOCK; rm -rf $LF; true
