#!/bin/sh
# 与 QML buildApiCmdForIps 生成的命令完全一致（原样粘贴）
rm -f /tmp/gdtest.out; if [ ! -s /tmp/gdtest.out ]; then r=$(LC_ALL=C curl -s --max-time 6 -A 'Mozilla/5.0' --resolve 'music-api.gdstudio.xyz:443:104.18.0.1' 'https://music-api.gdstudio.xyz/api.php?types=search&source=netease&name=test&count=1' 2>/dev/null); case "$r" in "["*|"{"*) printf '%s' "$r" > /tmp/gdtest.out;; esac; fi; if [ ! -s /tmp/gdtest.out ]; then r=$(LC_ALL=C curl -s --max-time 6 -A 'Mozilla/5.0' --resolve 'music-api.gdstudio.xyz:443:104.17.0.1' 'https://music-api.gdstudio.xyz/api.php?types=search&source=netease&name=test&count=1' 2>/dev/null); case "$r" in "["*|"{"*) printf '%s' "$r" > /tmp/gdtest.out;; esac; fi; if [ ! -s /tmp/gdtest.out ]; then r=$(LC_ALL=C curl -s --max-time 6 -A 'Mozilla/5.0' 'https://music-api.gdstudio.xyz/api.php?types=search&source=netease&name=test&count=1' 2>/dev/null); case "$r" in "["*|"{"*) printf '%s' "$r" > /tmp/gdtest.out;; esac; fi; printf '%s' 'GDDONE9Z' >> /tmp/gdtest.out

echo "--- 结果文件 ---"
cat /tmp/gdtest.out
echo
echo "--- 校验 ---"
case "$(cat /tmp/gdtest.out)" in
    *GDDONE9Z*) echo "  ✅ token 已写入";;
    *)          echo "  ❌ 无 token";;
esac
case "$(head -c 1 /tmp/gdtest.out)" in
    "[") echo "  ✅ 是 JSON 数组";;
    *)   echo "  ❌ 非 JSON";;
esac
