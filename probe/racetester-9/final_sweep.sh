#!/bin/sh
# final_sweep.sh —— 最终全盘清扫核查：确认设备上无 ractester 的任何残留
echo "=== 1. 我的目录 ==="
ls -ld /tmp/racetester-9 /tmp/racetester* 2>&1
echo ""
echo "=== 2. 我的 socket / 锁 ==="
ls -l /tmp/gdnext* /tmp/gdtest* /tmp/*audit* 2>&1
echo ""
echo "=== 3. 全设备进程（mpv 应为空）==="
ps w 2>&1 | grep -iE 'mpv|gdnext|silence|tone\.wav|racetester' | grep -v grep || echo "(none)"
echo ""
echo "=== 4. 生产件是否完好（不应被我改动）==="
ls -l /tmp/gdmusic.sock 2>&1
ls -ld /tmp/gdmusic 2>&1
ls -la /tmp/audio_wakelocks/ 2>&1
echo ""
echo "=== 5. 部署插件是否完好（只读核对）==="
ls -l /userdisk/PenMods/plugins/gdmusic/bin/gdnext.lua
sha256sum /userdisk/PenMods/plugins/gdmusic/bin/gdnext.lua 2>/dev/null || echo "(无 sha256sum)"
echo ""
echo "=== 6. /tmp 下与 gd 相关的其它目录（用于区分归属）==="
ls -ld /tmp/gd-* 2>&1
exit 0
