#!/bin/sh
# 带状态热重启：让正在播放的实例换成新版 gdnext.lua，且尽量不留感知。
#
# lua 脚本随 mpv 启动加载，改了 lua 就必须重启播放器才能生效 —— 没法热替换。
# 所以这里做的是「记下当前曲目/进度/暂停态 → 杀掉重拉 → 回到同一首同一位置」。
#
# 坑：queue.json 的 index 未必等于"当前正在播的那首"（lua 的自动续播不会回写队列），
#     所以重拉后要按歌名校正几次 gd-next，而不是无条件 seek。
#
# ⚠️ 必须前台等待（不能 & 后立刻返回）：adb shell 派生的后台进程会话结束即被清理。

IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl
SOCK=/tmp/gdmusic.sock
LOG=/tmp/gdmusic/lua.log
NAME_NOW=/tmp/gdmusic/now.json

prop() { LC_ALL=C "$IPC" "$SOCK" cmd get_property "$1" 2>/dev/null \
         | sed -n 's/.*"data":\([^,}]*\).*/\1/p'; }
jfield() { cat "$NAME_NOW" 2>/dev/null | sed -n "s/.*\"$1\":\([^,}]*\).*/\1/p"; }

# ---- 1. 记录现场 ----
POS=$(prop time-pos)
PAUSED=$(prop pause)
NAME=$(jfield name | tr -d '"')
ID=$(jfield id | tr -d '"')
[ -z "$POS" ] && POS=0
echo "重启前: name=$NAME pos=$POS pause=$PAUSED"

# ---- 2. 杀掉旧实例（连同 wrapper），并清掉可能残留的僵尸 socket ----
pkill -f "[i]nput-ipc-server=$SOCK" 2>/dev/null
sleep 2
rm -f "$SOCK"

# ---- 3. 重拉：必须 setsid，nohup 会在 adb 会话结束时被清理（实测）----
# 命令照抄 QML 的 ensurePlayer：不传 --volume（免两级叠乘）、保留 OOM 防线。
setsid /userdisk/mpv/mpv --no-video --force-window=no --idle=yes --keep-open=no \
      --demuxer-max-bytes=8MiB \
      --input-ipc-server="$SOCK" \
      --script=/userdisk/PenMods/plugins/gdmusic/bin/gdnext.lua \
      </dev/null > /tmp/gdmusic_mpv.log 2>&1 &
disown 2>/dev/null
sleep 6
# ⚠️ 存活判据用 pgrep -f：ps 在非 tty 管道里会截断长命令行 ⇒ 查不到反而误判"进程死了"
pgrep -f "[i]nput-ipc-server=$SOCK" >/dev/null || { echo "✗ 播放器没起来"; exit 1; }
echo "新实例 pid: $(pgrep -f "[i]nput-ipc-server=$SOCK" | tr '\n' ' ')"

# ---- 4. 回到刚才那一首 ----
LC_ALL=C "$IPC" "$SOCK" cmd script-message gd-load >/dev/null 2>&1
i=0
while [ $i -lt 25 ]; do
    sleep 1
    cur=$(jfield name | tr -d '"')
    [ -n "$cur" ] && [ "$cur" != "" ] && break
    i=$((i+1))
done
# queue.json 的 index 可能不是刚才那首（续播不会回写队列）⇒ 按歌名校正
 tries=0
while [ "$(jfield name | tr -d '"')" != "$NAME" ] && [ $tries -lt 20 ]; do
    LC_ALL=C "$IPC" "$SOCK" cmd script-message gd-next >/dev/null 2>&1
    sleep 2
    tries=$((tries+1))
done

echo "校正后: name=$(jfield name | tr -d '"') (尝试 $tries 次)"

# ---- 5. 回到原进度与原暂停态 ----
# ⚠️ seek 不能立马发：网络流的 demuxer 未就绪时会被 mpv 静默丢弃（踩过两次）。
# 先轮询到真的在播了（pos 抬过 1 秒），再 seek，最后还要校验一次。
for i in $(seq 20); do
    p=$(prop time-pos); [ -n "$p" ] && [ "${p%.*}" -gt 1 ] && break
    sleep 1
done
LC_ALL=C "$IPC" "$SOCK" cmd seek "$POS" absolute >/dev/null 2>&1
sleep 2
af=$(prop time-pos)
if [ -n "$af" ] && [ "${af%.*}" -lt 2 ]; then
    echo "seek 疑似失效（pos=$af），补一次"
    sleep 3
    LC_ALL=C "$IPC" "$SOCK" cmd seek "$POS" absolute >/dev/null 2>&1
    sleep 2
fi
if [ "$PAUSED" = "true" ]; then
    LC_ALL=C "$IPC" "$SOCK" cmd set_property pause true >/dev/null 2>&1
fi

# ---- 6. 复核 ----
sleep 2
echo "重启后: pos=$(prop time-pos) pause=$(prop pause)"
echo "now.json: $(cat $NAME_NOW | cut -c1-240)"
echo "lua.log:  $(tail -3 $LOG)"
