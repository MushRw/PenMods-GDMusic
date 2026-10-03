#!/bin/sh
# 设备端并发复现脚本：验证修复后的二维码流程不会再出现「码与 key 错配」。
#
# 复现的真实事故（2026-10-02 23:56）：ncStartLogin 在 5 秒内被调两次
#   → 23:56:13 申请 unikey 45206508
#   → 23:56:18 申请 unikey 71b6ab0a
# 两个 curl 并发 `rm -f 固定路径; curl -o 固定路径` ⇒ 最终落盘的是**第一个**的码，
# 而 ncUnikey 是**第二个** ⇒ 用户扫码授权的是 45206508，插件永远轮询 71b6ab0a。
#
# 修复两点：① 重入守卫；② 文件名带 unikey 前缀。
# 本脚本模拟「两次调用」，验证：两次的码落在**不同文件**、各自完整可解码。
set -e
T1=$(curl -s --max-time 12 -A 'Mozilla/5.0' -e 'https://music.163.com/' \
      -X POST -d 'type=1' 'https://music.163.com/api/login/qrcode/unikey' 2>/dev/null)
K1=$(echo "$T1" | sed -n 's/.*"unikey":"\([^"]*\)".*/\1/p')
T2=$(curl -s --max-time 12 -A 'Mozilla/5.0' -e 'https://music.163.com/' \
      -X POST -d 'type=1' 'https://music.163.com/api/login/qrcode/unikey' 2>/dev/null)
K2=$(echo "$T2" | sed -n 's/.*"unikey":"\([^"]*\)".*/\1/p')
echo "K1=$K1"
echo "K2=$K2"

# 与插件同款：--http1.1（pwmqr 在 h2 下 200+空 body）
I1="/tmp/gdmusic_ncqr_$(echo "$K1" | cut -c1-8).png"
I2="/tmp/gdmusic_ncqr_$(echo "$K2" | cut -c1-8).png"
Q() {
  curl -sL --http1.1 --max-time 15 -A 'Mozilla/5.0' -o "$1" \
    "https://api.pwmqr.com/qrcode/create/?url=$(printf '%s' "$2" | sed 's/:/%3A/g; s|/|%2F|g; s/?/%3F/g; s/=/%3D/g')" 2>/dev/null
}
# 故意不加 sleep：模拟两次调用的 curl **并发**写
Q "$I1" "https://music.163.com/login?codekey=$K1" &
Q "$I2" "https://music.163.com/login?codekey=$K2" &
wait

echo "--- 落盘结果 ---"
for f in "$I1" "$I2"; do
  if [ -s "$f" ]; then
    echo "$(basename $f) $(wc -c < $f) bytes  magic=$(head -c 4 "$f" | od -An -tx1 | tr -d ' ')"
  else
    echo "$(basename $f) MISSING_OR_EMPTY"
  fi
done
echo "K1_EXPECT=${I1}"
echo "K2_EXPECT=${I2}"
[ -s "$I1" ] && [ -s "$I2" ] && echo "RESULT=OK_TWO_DISTINCT" || echo "RESULT=FAIL"
