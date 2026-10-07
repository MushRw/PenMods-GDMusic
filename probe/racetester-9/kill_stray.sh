#!/bin/sh
# kill_stray.sh —— 干掉我自己遗留的 mpv（pid 8481 及其父 shell 8475）
# 判据：它的 cmdline 指向 /tmp/racetester-9/（我的隔离目录），
#       且 --msg-level=all=warn 正是我 mpvtest.sh / 早先调试命令的参数。
#       生产播放器用的是 /tmp/gdmusic.sock + --msg-level 不同 ⇒ 可区分。
echo "--- 杀前确认 8481 的身份 ---"
cat /proc/8481/cmdline 2>/dev/null | tr '\0' ' '; echo ""
echo "--- 它打开的 socket/文件（确认不是生产件）---"
ls -l /proc/8481/fd 2>/dev/null | head -20
echo ""
echo "--- 确认它不是生产播放器 ---"
if cat /proc/8481/cmdline 2>/dev/null | grep -q 'gdmusic.sock'; then
  echo "REFUSE: 8481 使用生产 socket，不动它"; exit 1
fi
echo "OK: 8481 未使用生产 socket，是我的遗留进程"
echo "--- 执行 kill ---"
kill 8481 2>/dev/null; sleep 1
kill -9 8481 2>/dev/null
kill 8475 2>/dev/null; sleep 1
kill -9 8475 2>/dev/null
sleep 1
echo "--- 杀后核查 ---"
for p in 8475 8481; do
  if [ -d /proc/$p ]; then echo "pid $p STILL ALIVE"; else echo "pid $p dead"; fi
done
echo "--- 全设备 mpv 残留 ---"
ps w 2>&1 | grep -iE 'mpv|gdnext|silence' | grep -v grep || echo "(none)"
echo "--- 清理我推的核查脚本 ---"
rm -f /tmp/racetester-final-check.sh
ls -l /tmp/racetester* 2>&1
exit 0
