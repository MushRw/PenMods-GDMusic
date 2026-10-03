#!/bin/sh
# 验证修复后的 buildNcQrWaitCmd：下载二维码 + 判非空 + 写 .done 完成信号
set -e
IMG=/tmp/gdmusic_nc_qr.png
DONE=/tmp/gdmusic_ncqr_test.done
TOKEN=GDDONE99Z
rm -f "$IMG" "$DONE"

k=$(LC_ALL=C curl -s --max-time 12 -A 'Mozilla/5.0' -e 'https://music.163.com/' \
      -X POST -d 'type=1' 'https://music.163.com/api/login/qrcode/unikey' 2>/dev/null \
    | sed -n 's/.*"unikey":"\([^"]*\)".*/\1/p')
echo "KEY=$k"
[ -z "$k" ] && { echo "FATAL no unikey"; exit 1; }

# 与 buildNcQrWaitCmd 完全同构的拼接
url="https://api.pwmqr.com/qrcode/create/?url=$(printf '%s' "https://music.163.com/login?codekey=$k" | sed 's/:/%3A/g; s|/|%2F|g; s/?/%3F/g; s/=/%3D/g')"
rm -f "$IMG"
curl -sL --http1.1 --max-time 15 -A 'Mozilla/5.0' -o "$IMG" "$url" >/dev/null 2>&1 || true
n=$(LC_ALL=C wc -c < "$IMG" 2>/dev/null || echo 0)
echo "BYTES=$n"
if [ "$n" -gt 0 ] 2>/dev/null; then printf '%s' "$TOKEN" > "$DONE"; fi

echo "DONE_EXISTS=$([ -f "$DONE" ] && echo yes || echo no)"
echo "DONE_CONTENT=$(cat "$DONE" 2>/dev/null)"
head -c 4 "$IMG" | od -c | head -1
