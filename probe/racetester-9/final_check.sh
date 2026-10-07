#!/bin/sh
# final_check.sh —— 核查 ractester 的所有进程与目录已清理
echo "--- 我的隔离目录（应为 No such file）---"
ls -ld /tmp/racetester-9 2>&1
echo "--- 所有 mpv/gdnext/silence 进程（应为 none）---"
ps w 2>&1 | grep -iE 'mpv|gdnext|silence' || echo "(none)"
echo "--- 逐个核查我起过的 pid ---"
for p in 5811 9661 16570 19659 21326 22077 22751 23529 23652; do
  if [ -d /proc/$p ]; then
    echo "pid $p ALIVE: $(cat /proc/$p/cmdline 2>/dev/null | tr '\0' ' ')"
  fi
done
echo "(以上为空 = 我起的 mpv 全部已死)"
echo "--- 生产状态目录（应不存在）---"
ls -ld /tmp/gdmusic 2>&1
echo "--- 生产 socket（应不存在）---"
ls -l /tmp/gdmusic.sock 2>&1
echo "--- 唤醒锁目录（VideoPlayer.lock 从未被我触碰）---"
ls -la /tmp/audio_wakelocks/ 2>&1
echo "--- /tmp 下是否还有我的痕迹 ---"
ls -ld /tmp/gdnext* /tmp/gdtest* /tmp/gd-* 2>&1 | head
exit 0
