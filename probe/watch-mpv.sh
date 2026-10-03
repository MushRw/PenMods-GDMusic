#!/bin/sh
# 受控实验：启动常驻播放器，观察它到底什么时候死、为什么死。
SOCK=/tmp/gdmusic.sock
IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl
LOG=/tmp/gdmusic/probe.log

rm -f "$SOCK" "$LOG"
echo "=== memory before ==="
grep -E 'MemFree|MemAvailable' /proc/meminfo

nohup /userdisk/mpv/mpv --no-video --force-window=no --idle=yes --keep-open=no \
  --volume=80 --demuxer-max-bytes=8MiB \
  --input-ipc-server="$SOCK" \
  --script=/userdisk/PenMods/plugins/gdmusic/bin/gdnext.lua \
  > /tmp/gdmusic_mpv.log 2>&1 &
WPID=$!
echo "wrapper pid=$WPID"

i=0
while [ $i -lt 25 ]; do
    MPID=$(LC_ALL=C "$IPC" "$SOCK" pid 2>/dev/null)
    ALIVE=$(pgrep -f '[i]nput-ipc-server=/tmp/gdmusic.sock' | tr '\n' ' ')
    MEMF=$(grep MemFree /proc/meminfo)
    echo "t=${i}s alive=[$ALIVE] mpvPid=[$MPID] $MEMF"
    if [ -z "$ALIVE" ]; then echo "!!! mpv 已消失 (t=${i}s)"; break; fi
    i=$((i+1))
    sleep 1
done

echo "=== wait 拿退出码 ==="
wait $WPID
echo "wrapper exit=$?"

echo "=== mpv.log 尾部 ==="
tail -12 /tmp/gdmusic_mpv.log
echo "=== lua.log 尾部 ==="
tail -8 /tmp/gdmusic/lua.log
echo "=== AudioDaemon 是否在管 ==="
ls -la /tmp/audio_wakelocks/ 2>&1
