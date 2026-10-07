#!/bin/sh
# nofile.sh —— 复现 MediaBridge.qml:226 那条 execAsync 命令的【原始字节输出】
#
# 目标（Lead 点名要）：验证「now.json 不存在」时那一拍的 raw 到底是什么，
# 从而判断 QML 侧会解析成什么。
#
# 逐字复刻 MediaBridge.qml:226-228 的命令形状：
#   if [ -f <now> ]; then cat <now>; else printf 'NOFILE'; fi; printf '\n@@\n';
#   if [ -S <sock> ]; then printf 'S\n'; else printf 'D\n'; fi
D=/tmp/racetester-9
NOW=$D/gdmusic/now.json
SOCK=$D/nofile-test.sock
mkdir -p $D/gdmusic

echo "=== 场景 A: 文件不存在 + socket 不存在（tmpfs 被清空后的冷启动拍）==="
rm -f "$NOW" "$SOCK"
CMD="if [ -f $NOW ]; then cat $NOW; else printf 'NOFILE'; fi; printf '\\n@@\\n'; if [ -S $SOCK ]; then printf 'S\\n'; else printf 'D\\n'; fi"
echo "--- 命令: $CMD"
OUT=$(sh -c "$CMD")
echo "--- 原始输出（od -c，显示不可见字节）---"
sh -c "$CMD" | od -c | head -8
echo "--- 解析：raw.split('@@') 后 ---"
printf '%s' "$OUT" | sed -n '1p' | sed 's/^/  parts[0]=/'
printf '%s' "$OUT" | sed -n '2p' | sed 's/^/  parts[1]=/'

echo ""
echo "=== 场景 B: 文件不存在 + socket 存在 ==="
rm -f "$NOW"
: > /dev/null
# 造一个真 unix socket：用 mpv 起（最贴近真实），或用 perl 起一个 listener
perl -MSocket -e '
  use strict; use Socket;
  my $p = shift;
  unlink $p;
  socket(my $s, PF_UNIX, SOCK_STREAM, 0) or die "socket: $!";
  bind($s, sockaddr_un($p)) or die "bind: $!";
  listen($s, 5) or die "listen: $!";
  open(my $f, ">", "/tmp/racetester-9/nofile-sock.pid"); print $f "$$\n"; close $f;
  sleep 25;
' "$SOCK" &
SPID=$!
sleep 1.5
ls -l "$SOCK"
echo "--- 原始输出（od -c）---"
sh -c "$CMD" | od -c | head -8
echo "--- 解析 ---"
OUT2=$(sh -c "$CMD")
printf '%s' "$OUT2" | sed -n '1p' | sed 's/^/  parts[0]=/'
printf '%s' "$OUT2" | sed -n '2p' | sed 's/^/  parts[1]=/'
kill $SPID 2>/dev/null
rm -f "$SOCK" "$D/nofile-sock.pid"

echo ""
echo "=== 场景 C: 文件存在且完整（对照）==="
printf '{"ts":1,"seq":9}' > "$NOW"
sh -c "$CMD" | od -c | head -8

echo ""
echo "=== 场景 D: 文件存在但 0 字节（撕裂读命中那一拍）==="
: > "$NOW"
sh -c "$CMD" | od -c | head -8

echo ""
echo "=== 场景 E: 文件存在但半截（不以 } 结尾）==="
printf '{"ts":1,"seq":9,"name":"半' > "$NOW"
sh -c "$CMD" | od -c | head -8

rm -f "$NOW" "$SOCK"
echo ""
echo "=== CLEANUP done ==="
exit 0
