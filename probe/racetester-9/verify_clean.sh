#!/bin/sh
# verify_clean.sh —— 收尾核查：证明本任务只在自己的隔离区留下东西
echo "=== 最终状态核查 ==="
echo "--- 我的隔离目录（本次测量的全部产物）---"
ls -la /tmp/racetester-9/ 2>&1
echo "--- 生产状态目录 /tmp/gdmusic（应不存在）---"
ls -ld /tmp/gdmusic 2>&1
echo "--- 生产 socket /tmp/gdmusic.sock（应不存在）---"
ls -l /tmp/gdmusic.sock 2>&1
echo "--- 唤醒锁目录（本任务只写 gdtest.lock，已删；VideoPlayer.lock 从未触碰）---"
ls -la /tmp/audio_wakelocks/ 2>&1
echo "--- 我起的 mpv 残留（应无）---"
ps w 2>&1 | grep "[g]dnext-audit" || echo "(无 gdnext-audit 进程)"
ps w 2>&1 | grep "[s]ilence.mp3" || echo "(无 silence.mp3 进程)"
echo "--- 生产 mpv socket（应无）---"
ls -l /tmp/mpvsocket 2>&1
exit 0
