#!/bin/sh
# ============================================================
# ⚠️ NOT-A-TEST —— 这是**诊断打印件**，不是断言件。
#
# 本文件只 echo 观察结果，没有 pass/bad 判定，也**不会**因为失败而返回非 0。
# ⇒ 它的"绿"不构成任何回归保护，别把它当门禁看。
#
# 2026-10-05 标注：探针目录里"真断言件"与"诊断打印件"混在一起，
# 新人看到满屏 ✅ 就以为验过了 —— 而这一类压根没有 ✅。
# 真断言件长这样：有 pass/bad 计数、结尾 `exit 1`、输出被别的 .sh grep
# （例：addpick-device.sh:47 `grep -q "bad=0"`、login-device.sh:39、
#       sidecar-e2e.sh 的 ok/bade 体系）。
# 判定脚本想变断言件：加 bad 计数 + 结尾 `exit $bad`，别只改文案。
# 详细清单见 audit-report/gdmusic-probe-ref.md 第一节 C。
# ============================================================
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
