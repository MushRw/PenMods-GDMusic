#!/bin/sh
# 8821 触发点实验：同一 unikey 反复 check，看第几次变 8821
#
# 背景（为什么现在怀疑"同一 key 反复 check"）：
#   09:25:32 申请 b00da8b7 → 09:25:37 check(1) = 802 授权中 → 09:25:38 check(2) = 8821
#   09:27:05 申请 3d17357c → 09:27:09 check = 801 → 09:27:14 check = 801 → 09:27:17 check = 8821
#   而 nc-8821-header3.sh 里 6 个**各自独立的 unikey、各只 check 一次**，全部 801
#   ⇒ 差异不在 header，在"同一个 key 被 check 了几次"。
#
# 本实验：一个 unikey，每 3s check 一次（与插件当前轮询间隔一致），连打 8 次。
# 判读：
#   第 N 次变 8821  ⇒ 上限是 N-1 次，轮询策略必须按"总次数"而非"间隔"来设计
#   全程 801        ⇒ 假设不成立，得看别的（那就更可能是扫码动作本身触发）
#
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'

k=$(LC_ALL=C curl -s --max-time 12 -A "$UA" -e 'https://music.163.com/' \
    -X POST -d 'type=1' 'https://music.163.com/api/login/qrcode/unikey' 2>/dev/null \
    | sed -n 's/.*"unikey":"\([^"]*\)".*/\1/p')
echo "unikey=$k"
[ -z "$k" ] && { echo "NO_UNIKEY"; exit 1; }

i=1
while [ $i -le 8 ]; do
  printf 'GET  #%d t=%ds: ' "$i" "$(( (i-1) * 3 ))"
  LC_ALL=C curl -s --max-time 12 -A "$UA" -e 'https://music.163.com/' \
    "https://music.163.com/api/login/qrcode/client/login?key=$k&type=1" 2>/dev/null | head -c 80
  echo
  i=$((i + 1))
  sleep 3
done

echo "--- 同一 key 再试 POST 明文（官方是 weapi 加密的 POST；看明文 POST 是否不同待遇） ---"
k2=$(LC_ALL=C curl -s --max-time 12 -A "$UA" -e 'https://music.163.com/' \
     -X POST -d 'type=1' 'https://music.163.com/api/login/qrcode/unikey' 2>/dev/null \
     | sed -n 's/.*"unikey":"\([^"]*\)".*/\1/p')
echo "unikey2=$k2"
[ -z "$k2" ] && { echo "NO_UNIKEY2"; exit 1; }
i=1
while [ $i -le 6 ]; do
  printf 'POST #%d t=%ds: ' "$i" "$(( (i-1) * 3 ))"
  LC_ALL=C curl -s --max-time 12 -A "$UA" -e 'https://music.163.com/' \
    -X POST -d "key=$k2&type=1" \
    'https://music.163.com/api/login/qrcode/client/login' 2>/dev/null | head -c 80
  echo
  i=$((i + 1))
  sleep 3
done
echo "=== DONE ==="
