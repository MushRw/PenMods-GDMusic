#!/bin/sh
# 唤醒锁闭环实测：直接执行「插件 buildWakeLockCmd() 的原样输出」(/tmp/wakecmd.txt)
SOCK=/tmp/gdmusic.sock
LOCK=/tmp/audio_wakelocks/gdmusic.lock
IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

pkill -f '[i]nput-ipc-server='"$SOCK" 2>/dev/null
rm -f "$SOCK" "$LOCK"; sleep 1

echo "== 启动 mpv =="
nohup /userdisk/mpv/mpv --no-video --force-window=no --idle=yes --volume=80 \
      --input-ipc-server="$SOCK" "https://music-api.gdstudio.xyz/api.php" >/tmp/wl_mpv.log 2>&1 &

echo "== 执行插件的唤醒锁命令（原样） =="
sh /tmp/wakecmd.txt
echo "  rc=$?"

echo "== 校验 =="
if [ -f "$LOCK" ]; then ok "锁文件已创建"; else bad "锁文件未创建"; fi
M=$(cat "$LOCK" 2>/dev/null)
echo "  锁内容(pid)=$M"
if [ -n "$M" ] && [ -d "/proc/$M" ]; then
    ok "锁内 PID 存活且 comm=$(cat /proc/$M/comm 2>/dev/null)"
else
    bad "锁内 PID 无效"
fi
# 交叉核对：mpv 自报的 pid 是否就是锁里那个
MP=$(LC_ALL=C "$IPC" "$SOCK" pid 2>/dev/null)
echo "  mpv 再报 pid=$MP"
[ "$M" = "$MP" ] && ok "锁 PID 与 mpv 自报一致" || bad "锁 PID 与 mpv 自报不一致"

echo "== 收播：执行插件 killMpv 的原样命令 =="
sh -c "LC_ALL=C pkill -f '[i]nput-ipc-server=$SOCK' 2>/dev/null; rm -f $LOCK; true"
sleep 1
[ -f "$LOCK" ] && bad "锁未释放" || ok "锁已释放"
pgrep -f '[i]nput-ipc-server='"$SOCK" >/dev/null 2>&1 && bad "mpv 仍在" || ok "mpv 已退出"
rm -f "$SOCK"

echo
echo "== 汇总 PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ] || exit 1
