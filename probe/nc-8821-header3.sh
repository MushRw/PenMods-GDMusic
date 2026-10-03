#!/bin/sh
# 8821 对照实验（第二版，控制变量）
#
# 上一版实验的致命缺陷：拿**同一个 unikey** 试 5 种 header。而 801 是"还没人扫"
# 的常态 —— 无论 header 如何都返 801，所以"5 种全返 801"根本证伪不了任何东西，
# 反而让我误判成"header 无关、纯粹是限频"，朝降频方向白改了一轮。
#
# 这一版的控制点：
#   ① 每种 header 用**自己独立的 unikey**（避免"同一 key 被 check 多次"污染结果）
#   ② 每个 unikey **只 check 一次**（把"check 次数"这个变量固定为 1）
#   ③ 5 组**串行但紧邻**执行（都在同一时间窗内，排除"等一会儿风控就解了"）
#
# 判读：
#   - 某组返 801 / 其它组返 8821   ⇒ header 有效，照那组改
#   - 全部返 8821                  ⇒ 是 IP/时间维度的风控（需冷却），header 救不了
#
UA_BARE='Mozilla/5.0'
UA_FULL='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
UA_PC='Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/35.0.1916.157 Safari/537.36 NeteaseMusicDesktop'

ask() {
  LC_ALL=C curl -s --max-time 12 -A "$UA_FULL" -e 'https://music.163.com/' \
    -X POST -d 'type=1' 'https://music.163.com/api/login/qrcode/unikey' 2>/dev/null \
    | sed -n 's/.*"unikey":"\([^"]*\)".*/\1/p'
}

echo "=== 1) 裸 UA（当前实现） ==="
k=$(ask); echo "unikey=$k"
[ -n "$k" ] && LC_ALL=C curl -s --max-time 12 -A "$UA_BARE" -e 'https://music.163.com/' \
  "https://music.163.com/api/login/qrcode/client/login?key=$k&type=1" 2>/dev/null | head -c 90; echo

echo "=== 2) 完整 Chrome UA ==="
k=$(ask); echo "unikey=$k"
[ -n "$k" ] && LC_ALL=C curl -s --max-time 12 -A "$UA_FULL" -e 'https://music.163.com/' \
  "https://music.163.com/api/login/qrcode/client/login?key=$k&type=1" 2>/dev/null | head -c 90; echo

echo "=== 3) 完整 Chrome UA + Cookie: os=pc ==="
k=$(ask); echo "unikey=$k"
[ -n "$k" ] && LC_ALL=C curl -s --max-time 12 -A "$UA_FULL" -e 'https://music.163.com/' \
  -H 'Cookie: os=pc; appver=2.9.7' \
  "https://music.163.com/api/login/qrcode/client/login?key=$k&type=1" 2>/dev/null | head -c 90; echo

echo "=== 4) 网易云 PC 客户端 UA + os=pc ==="
k=$(ask); echo "unikey=$k"
[ -n "$k" ] && LC_ALL=C curl -s --max-time 12 -A "$UA_PC" -e 'https://music.163.com/' \
  -H 'Cookie: os=pc; appver=2.9.7' \
  "https://music.163.com/api/login/qrcode/client/login?key=$k&type=1" 2>/dev/null | head -c 90; echo

echo "=== 5) 完整 UA + os=pc + NMTID（复用已存 jar） ==="
k=$(ask); echo "unikey=$k"
N=$(sed -n 's/.*NMTID[[:space:]]*\([^[:space:]]*\).*/\1/p' /tmp/gdmusic_nc_cookie.jar 2>/dev/null | head -1)
echo "NMTID=$N"
[ -n "$k" ] && LC_ALL=C curl -s --max-time 12 -A "$UA_FULL" -e 'https://music.163.com/' \
  -H "Cookie: os=pc; appver=2.9.7; NMTID=$N" \
  "https://music.163.com/api/login/qrcode/client/login?key=$k&type=1" 2>/dev/null | head -c 90; echo

echo "=== 6) 再裸 UA 一次（对照组：确认不是\"等一会儿就好了\"） ==="
k=$(ask); echo "unikey=$k"
[ -n "$k" ] && LC_ALL=C curl -s --max-time 12 -A "$UA_BARE" -e 'https://music.163.com/' \
  "https://music.163.com/api/login/qrcode/client/login?key=$k&type=1" 2>/dev/null | head -c 90; echo

echo "=== DONE ==="
