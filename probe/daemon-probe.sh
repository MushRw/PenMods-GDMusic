#!/bin/sh
echo "=== 1. perl 能力 ==="
perl -v 2>&1 | sed -n '2p'
for m in JSON::PP IO::Socket::UNIX POSIX Fcntl Time::HiRes; do
  perl -M$m -e '1' 2>/dev/null && echo "   $m = OK" || echo "   $m = 缺失"
done
echo "   fork/exec 测试: $(perl -e 'my $p=fork(); if(!$p){exec("echo","child-ok"); exit} wait; ' 2>&1)"
echo "   open -| 测试: $(perl -e 'open(my $f,"-|","echo","pipe-ok"); print <$f>' 2>&1)"
echo "   select 超时读测试: $(perl -e 'my $s=select(STDIN); $|=1; print "sel-ok"' 2>&1)"

echo
echo "=== 2. shell 工具 ==="
for c in setsid flock nohup pgrep pkill timeout date awk sed tr mkdir; do
  printf "   %-8s = %s\n" "$c" "$(command -v $c 2>/dev/null || echo 缺失)"
done
echo "   date 纳秒: $(date +%s%N 2>/dev/null)"
echo "   /tmp 文件系统: $(df -T /tmp 2>/dev/null | tail -1 | awk '{print $2}')"

echo
echo "=== 3. mpv 能力（lua 备选方案）==="
/userdisk/mpv/mpv --version 2>&1 | head -3
echo "   --- 可用脚本目录（有 lua 才会有）---"
ls /userdisk/mpv/ 2>/dev/null
find / -maxdepth 5 -name '*.lua' -path '*mpv*' 2>/dev/null | head -5

echo
echo "=== 4. 现有 mpv 进程与唤醒锁现状 ==="
ps w 2>/dev/null | grep -E '[m]pv' | head -5
echo "   --- wakelocks ---"
ls -la /tmp/audio_wakelocks/ 2>&1

echo
echo "=== 5. 常驻 perl 进程的内存占用参考 ==="
perl -MIO::Socket::UNIX -MJSON::PP -e 'sleep 3' &
sleep 1
PP=$(pgrep -f 'sleep 3' | head -1)
[ -n "$PP" ] && echo "   pid=$PP $(grep -E 'VmRSS' /proc/$PP/status 2>/dev/null)"
wait 2>/dev/null
echo "done"
