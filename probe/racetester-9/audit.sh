#!/bin/sh
# audit.sh —— 对真 lua 写出的 now.json 做多速率采样
# 采样率越高，越接近「文件处于坏状态的时间占比」⇒ 反推真机 W
D=/tmp/racetester-9
NOW=$D/gdmusic/now.json

echo "=== 真 lua now.json 采样（写者 = 真 mpv+gdnext.lua，1 Hz） ==="
for R in 0 2000 10000; do
  echo "--- reader period_us=$R ---"
  perl $D/audit_read.pl "$NOW" 60 "$R" 2>/dev/null
  echo ""
done
