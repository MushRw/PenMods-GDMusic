#!/bin/sh
# 验证「解析 IPv4 -> 逐 IP 轮换重试」策略的成功率
set -u
B="https://music-api.gdstudio.xyz/api.php?types=search&source=netease&name=test&count=1"
UA="Mozilla/5.0"
HOST="music-api.gdstudio.xyz"

echo "== 解析 IPv4 =="
IPS=$(busybox nslookup "$HOST" 2>/dev/null | sed -n 's/.*Address [0-9]*: *\([0-9.]*\)$/\1/p')
echo "  轮换列表: $(echo $IPS | tr '\n' ' ')"

if [ -z "$IPS" ]; then echo "FAIL: 解析不到 IPv4"; exit 1; fi

ok=0; bad=0
i=1
while [ $i -le 6 ]; do
    got=""
    for ip in $IPS; do
        r=$(curl -s -o /tmp/rot.json -w "%{http_code}:%{time_total}" --max-time 6 \
             --resolve "$HOST:443:$ip" -A "$UA" "$B")
        case "$r" in
            200:*) got="$ip $r"; break;;
        esac
    done
    if [ -n "$got" ]; then
        echo "  #$i 成功  走 $got"
        ok=$((ok + 1))
    else
        echo "  #$i 失败  两个 IP 都没通"
        bad=$((bad + 1))
    fi
    i=$((i + 1))
    sleep 1
done

echo "== 轮换策略结果: 成功 $ok / 失败 $bad =="
