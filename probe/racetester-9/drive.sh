#!/bin/sh
# drive.sh —— 真机撕裂读竞态驱动器：起【两个独立进程】（写者 + 读者）并发跑
#
# 用法: sh drive.sh <tag> <dur_s> <writer_period_us> <reader_period_us> [flush]
#
# 关键：写者与读者必须是两个真进程。同进程内顺序执行时读写永不重叠，
# 测出恒 0 坏读 —— 那是夹具无效，不是「没问题」。
TAG=$1
DUR=${2:-5}
WP=${3:-0}
RP=${4:-0}
FLUSH=${5:-0}
D=/tmp/racetester-9
P=$D/race_$TAG.json

echo "=== RACE tag=$TAG dur=${DUR}s writer_period_us=$WP reader_period_us=$RP flush=$FLUSH ==="
echo "cpu: $(grep -c ^processor /proc/cpuinfo) cores"

rm -f "$P"
# 写者后台，读者前台，两者同时存活
perl $D/race.pl write "$P" 205 "$DUR" "$WP" "$FLUSH" 2>/dev/null > $D/out_w_$TAG.txt &
WPID=$!
sleep 0.15
perl $D/race.pl read "$P" 205 "$DUR" "$RP" 2>/dev/null > $D/out_r_$TAG.txt
wait $WPID

cat $D/out_w_$TAG.txt
cat $D/out_r_$TAG.txt
