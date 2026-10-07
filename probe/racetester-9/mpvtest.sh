#!/bin/sh
# mpvtest.sh —— 确认 mp3 能被真机 mpv 解码并推进 time-pos
D=/tmp/racetester-9
LD_LIBRARY_PATH=/userdisk/mpv/lib timeout 10 /userdisk/mpv/bin/mpv \
  --no-config --no-video --ao=null --volume=0 --msg-level=all=warn \
  "$D/silence.mp3" > $D/decode_test.log 2>&1
echo "EXIT=$?"
grep -viE 'fontconfig|libass' $D/decode_test.log | head -10
echo "--- (empty above = 解码无报错) ---"
