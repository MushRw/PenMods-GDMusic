#!/bin/sh
# 设备端演练：插件同款命令走登录链路（unikey -> 二维码下载）
r=$(LC_ALL=C curl -s --max-time 12 -A 'Mozilla/5.0' -e 'https://music.163.com/' -X POST -d 'type=1' 'https://music.163.com/api/login/qrcode/unikey' 2>/dev/null)
echo "RESP:$r"
k=$(echo "$r" | sed -n 's/.*"unikey":"\([^"]*\)".*/\1/p')
echo "KEY:$k"
rm -f /tmp/gdmusic_nc_qr.png
enc=$(printf '%s' "https://music.163.com/login?codekey=$k" | sed 's/:/%3A/g; s|/|%2F|g; s/?/%3F/g; s/=/%3D/g')
curl -sL --http1.1 --max-time 15 -A 'Mozilla/5.0' -o /tmp/gdmusic_nc_qr.png "https://api.pwmqr.com/qrcode/create/?url=$enc"
ls -l /tmp/gdmusic_nc_qr.png
head -c 4 /tmp/gdmusic_nc_qr.png | od -c | head -1
