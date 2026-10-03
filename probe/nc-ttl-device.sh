#!/bin/sh
# 测量 unikey 的实际存活时长：申请后每 3s 轮询一次，打时间戳，直到状态变化
t0=$(date +%s)
r=$(LC_ALL=C curl -s --max-time 12 -A 'Mozilla/5.0' -e 'https://music.163.com/' -X POST -d 'type=1' 'https://music.163.com/api/login/qrcode/unikey' 2>/dev/null)
k=$(echo "$r" | sed -n 's/.*"unikey":"\([^"]*\)".*/\1/p')
echo "UNIREQ_T=$t0"
echo "UNIRESP=$r"
echo "KEY=$k"
[ -z "$k" ] && { echo "FATAL: unikey 申请失败"; exit 1; }

# 立刻出码并记录
rm -f /tmp/gdmusic_nc_qr.png
enc=$(printf '%s' "https://music.163.com/login?codekey=$k" | sed 's/:/%3A/g; s|/|%2F|g; s/?/%3F/g; s/=/%3D/g')
echo "ENC_URL=$enc"
curl -sL --http1.1 --max-time 15 -A 'Mozilla/5.0' -o /tmp/gdmusic_nc_qr.png "https://api.pwmqr.com/qrcode/create/?url=$enc"
echo "QR_BYTES=$(wc -c < /tmp/gdmusic_nc_qr.png)"

# 轮询到底
i=0
while [ $i -lt 45 ]; do
  now=$(date +%s)
  body=$(LC_ALL=C curl -s --max-time 10 -A 'Mozilla/5.0' -e 'https://music.163.com/' "https://music.163.com/api/login/qrcode/client/login?key=$k&type=1" 2>/dev/null)
  code=$(echo "$body" | sed -n 's/.*"code":\([0-9-]*\).*/\1/p')
  echo "T+$((now - t0))s code=$code"
  if [ "$code" != "801" ]; then
    echo "CHANGED_AT=$((now - t0))s"
    echo "BODY=$body"
    break
  fi
  i=$((i + 1))
  sleep 3
done
echo "TOTAL_ELAPSED=$(( $(date +%s) - t0 ))s"
