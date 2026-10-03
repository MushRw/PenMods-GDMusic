#!/bin/sh
# 验证"改造后的请求头"在真机上可用：完整 UA + Accept/Accept-Language + os=pc jar
#
# 直接照抄 main.qml 里 ncCurlHdr / buildNcSeedJarCmd / buildNcCheckCmd 产出的命令形状，
# 目的是确认：① 命令能跑通 ② unikey 申请正常 ③ 轮询正常 ④ jar 里确实带上 os=pc
#
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
JAR=/tmp/gdmusic_nc_cookie.jar

echo "=== 1) 种 jar（os=pc / appver） ==="
rm -f "$JAR"
touch "$JAR"
grep -q '^[^	]*	[^	]*	[^	]*	[^	]*	[^	]*	os	' "$JAR" 2>/dev/null || \
  printf 'music.163.com\tFALSE\t/\tFALSE\t0\tos\tpc\nmusic.163.com\tFALSE\t/\tFALSE\t0\tappver\t2.9.7\n' >> "$JAR"
cat "$JAR"

echo "=== 2) 申请 unikey（完整 UA + 全套头） ==="
K=$(LC_ALL=C curl -s --max-time 12 -A "$UA" -e 'https://music.163.com/' \
    -H 'Accept: */*' -H 'Accept-Language: zh-CN,zh;q=0.9' \
    -X POST -d 'type=1' 'https://music.163.com/api/login/qrcode/unikey' 2>/dev/null \
    | sed -n 's/.*"unikey":"\([^"]*\)".*/\1/p')
echo "unikey=$K"
[ -z "$K" ] && { echo "FAIL_NO_UNIKEY"; exit 1; }

echo "=== 3) 用新头轮询 3 次（看是否仍 801、jar 是否带上 os=pc） ==="
i=1
while [ $i -le 3 ]; do
  printf 'check #%d: ' "$i"
  LC_ALL=C curl -s --max-time 12 -A "$UA" -e 'https://music.163.com/' \
    -H 'Accept: */*' -H 'Accept-Language: zh-CN,zh;q=0.9' \
    -c "$JAR" -b "$JAR" \
    "https://music.163.com/api/login/qrcode/client/login?key=$K&type=1" 2>/dev/null | head -c 80
  echo
  i=$((i + 1))
  sleep 3
done

echo "=== 4) 轮询后 jar 内容（应有 os=pc + NMTID） ==="
cat "$JAR"

echo "=== 5) 二维码下载（图床 + --http1.1） ==="
PNG=/tmp/gdmusic_ncqr_$(echo "$K" | cut -c1-8).png
rm -f "$PNG"
curl -sL --http1.1 --max-time 15 -A "$UA" -o "$PNG" \
  "https://api.pwmqr.com/qrcode/create/?url=$(printf '%s' "https://music.163.com/login?codekey=$K" | sed 's/:/%3A/g; s/\//%2F/g; s/?/%3F/g; s/=/%3D/g')"
ls -l "$PNG" 2>/dev/null
head -c 4 "$PNG" 2>/dev/null | od -An -tx1 | head -1
echo "=== DONE ==="
