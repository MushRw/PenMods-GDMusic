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
