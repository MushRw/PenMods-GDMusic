#!/bin/sh
# 诊断网易云 QR 登录返回 8821（风控）的真实触发条件。
#
# 假设候选：
#   A. 请求头缺 Cookie（unikey 申请时下发的 NMTID 没带去 check）
#   B. 短时间申请太多 unikey / 轮询太密 ⇒ IP 级风控（跟 header 无关）
#
# 做法：同一个 unikey，分别用 4 种 header 组合去 check，看 code 是否不同。
#       若 4 种全是 8821 ⇒ 是 B（IP 被风控），加 header 无用，只能等 + 降频。
#       若某种组合能拿到 801 ⇒ 是 A，按那种组合修即可。
D=/tmp/nc8821
rm -rf $D; mkdir -p $D
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'

echo "=== 1) 申请 unikey（存 cookie jar）==="
curl -s --max-time 12 -A "$UA" -e 'https://music.163.com/' \
     -c $D/jar -X POST -d 'type=1' \
     'https://music.163.com/api/login/qrcode/unikey' -o $D/unikey.out
echo "unikey 响应: $(cat $D/unikey.out)"
K=$(sed -n 's/.*"unikey":"\([^"]*\)".*/\1/p' $D/unikey.out)
echo "K=$K"
echo "jar: $(cat $D/jar 2>/dev/null | tr '\n' '|')"

if [ -z "$K" ]; then echo "ABORT_NO_UNIKEY"; exit 1; fi

echo
echo "=== 2) 四种 header 组合分别 check（同一个 key）==="

echo "-- A: 裸 UA（当前插件的做法，不带任何 cookie）--"
curl -s --max-time 12 -A "$UA" \
     "https://music.163.com/api/login/qrcode/client/login?key=$K&type=1" -o $D/a.out
echo "   => $(head -c 120 $D/a.out)"

echo "-- B: UA + Referer --"
curl -s --max-time 12 -A "$UA" -e 'https://music.163.com/' \
     "https://music.163.com/api/login/qrcode/client/login?key=$K&type=1" -o $D/b.out
echo "   => $(head -c 120 $D/b.out)"

echo "-- C: UA + Referer + jar 里的 cookie（NMTID 等）--"
curl -s --max-time 12 -A "$UA" -e 'https://music.163.com/' -b $D/jar \
     "https://music.163.com/api/login/qrcode/client/login?key=$K&type=1" -o $D/c.out
echo "   => $(head -c 120 $D/c.out)"

echo "-- D: UA + Referer + 'os=pc; appver=8.9.70' 固定 cookie --"
curl -s --max-time 12 -A "$UA" -e 'https://music.163.com/' -H 'Cookie: os=pc; appver=8.9.70' \
     "https://music.163.com/api/login/qrcode/client/login?key=$K&type=1" -o $D/d.out
echo "   => $(head -c 120 $D/d.out)"

echo "-- E: 完整桌面端伪装（os=pc + appver + NMTID from jar）--"
NMTID=$(grep -o 'NMTID[[:space:]]*[^[:space:]]*' $D/jar | head -1 | awk '{print $2}')
curl -s --max-time 12 -A "$UA" -e 'https://music.163.com/' \
     -H "Cookie: os=pc; appver=8.9.70; NMTID=$NMTID" \
     "https://music.163.com/api/login/qrcode/client/login?key=$K&type=1" -o $D/e.out
echo "   => $(head -c 120 $D/e.out)"
echo "   (NMTID=$NMTID)"

echo
echo "=== 3) 再申请一次 unikey，看申请接口本身是否也被风控 ==="
curl -s --max-time 12 -A "$UA" -e 'https://music.163.com/' \
     -X POST -d 'type=1' \
     'https://music.163.com/api/login/qrcode/unikey' -o $D/unikey2.out
echo "第二次 unikey 响应: $(cat $D/unikey2.out)"

echo
echo "=== 4) 休息 30s 后再 check 一次同一 key（验证是否为限频）==="
sleep 30
curl -s --max-time 12 -A "$UA" -e 'https://music.163.com/' -b $D/jar \
     "https://music.163.com/api/login/qrcode/client/login?key=$K&type=1" -o $D/f.out
echo "   => $(head -c 120 $D/f.out)"
echo "DONE"
