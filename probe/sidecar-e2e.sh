#!/bin/bash
# 端到端验证 sidecar 的**命令生成** —— node 从 main.qml 抠出真源码求值，
# 拿到 buildCoverCmd / buildScanCmd 的真实输出，推到设备上真跑，再断言结果。
#
# 为什么必须这么测（技能 §3.5 的原话）：
#   "假数据只测解析、测不到拼接"。qmlscene 探针里没有 shell 上下文属性，
#   所以 sidecar-device.qml 只能验纯逻辑与分支；命令在 /bin/sh 下到底跑不跑得通、
#   封面有没有真的落盘、扫描命令认不认得出新文件 —— 只能在这里验。
#   ⚠️ 早先 sidecar-device.qml 里我自己声明了一个"假 shell"来跑命令，
#      那是自欺欺人（测的是假实现，不是 sh）。已删除，改由本脚本承担。
#
# ⛔ 为什么求值放在 sidecar-eval.js 而不是本文件里的 heredoc：
#   `EVAL=$(node - <<'JS' ... JS)` 这种写法，bash 解析命令替换时会把 JS 先
#   当 shell 词法扫一遍 —— `import QtQuick 5.15` 直接变成 "import: command not
#   found"，脚本跑飞。heredoc 只有**紧跟在命令后面**时才不被解析。
#   ⇒ 凡是 JS 里必然出现 $(、引号、括号的求值，一律走独立 .js 文件。
#
# 前置：设备上 /userdisk/Music/GDMusic/ 可写（真实目录，探针会清理自己造的样本）。
set -euo pipefail

S="${ADB_SERIAL:-}"
[ -n "$S" ] || { echo "需要设备序列号：先跑 adb devices 查到，再 export ADB_SERIAL=<序列号>"; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && (pwd -W 2>/dev/null || pwd))"
QML="$ROOT/plugin/qml/main.qml"
EVALJS="$ROOT/probe/sidecar-eval.js"
NODE="${NODE:-}"
# ⛔ MSYS_NO_PATHCONV 必须 export：否则 Git Bash 会把 "/userdisk/..." 这个
#    **设备路径**当成 Windows 路径改写成 C:/Users/.../PortableGit/userdisk/...
#    （踩过：node 收到的 argv 已经不是我们要的路径了）
export MSYS_NO_PATHCONV=1

[ -x "$NODE" ] || NODE=$(command -v node)
[ -f "$QML" ] || { echo "找不到 $QML"; exit 1; }
[ -f "$EVALJS" ] || { echo "找不到 $EVALJS"; exit 1; }

DD=/userdisk/Music/GDMusic
SAMPLE="$DD/e2e侧车测试-某歌手"
MP3="$SAMPLE.mp3"
IMG_URL="https://p2.music.126.net/81BsxxhomJ4aJZYvEbyPkw==/109951165671182684.jpg?param=500y500"
OUTJSON="$ROOT/.tmp/sidecar-e2n-eval.json"
mkdir -p "$ROOT/.tmp"

# 设备命令一律串行，且每条都带 -s
d() { adb -s "$S" shell "$1" </dev/null; }

pass=0; bad=0
ok()   { pass=$((pass+1)); echo "  ✅ $1"; }
bade() { bad=$((bad+1));  echo "  ❌ $1"; }

# 从 eval json 取字段（node 读，避免 shell 反复解析 JSON）
jget() { "$NODE" -e 'const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(o[process.argv[2]]))' "$OUTJSON" "$1"; }

echo "=== 0. node 求值真源码 ==="
if "$NODE" "$EVALJS" "$QML" "$MP3" "$IMG_URL" > "$OUTJSON" 2> "$ROOT/.tmp/sidecar-e2e-err.txt"; then
    ok "main.qml 里的 buildCoverCmd / buildScanCmd 求值成功"
else
    bade "求值失败："; cat "$ROOT/.tmp/sidecar-e2e-err.txt"; exit 1
fi

COVER_CMD=$(jget cover)
SCAN_CMD=$(jget scan)
EXT=$(jget ext)
MARKI=$(jget markImg)
MARKM=$(jget markMp3)
TMPD=$(jget tmpDir)

# ⛔ 求值器要是没抠出标记，这里会是空串，grep -c "^" 会数出所有行 ⇒ 断言假绿。
#    所以先钉死"标记非空"，再往下走。
if [ -z "$MARKI" ] || [ -z "$MARKM" ]; then
    bade "求值结果里扫描标记为空（markImg='$MARKI' markMp3='$MARKM'）—— 探针本身坏了，先别看下面的断言"
    exit 1
fi

echo "  推断扩展名 = $EXT"
echo "  扫描标记   = mp3:$MARKM  img:$MARKI"
echo "  --- 封面命令 ---"
printf '    %s\n' "$COVER_CMD"
echo "  --- 扫描命令 ---"
printf '    %s\n' "$SCAN_CMD"
echo ""

echo "=== 1. 清理上一次的残留 ==="
d "rm -f '$MP3' '$SAMPLE.jpg' '$SAMPLE.png' '$SAMPLE.lrc' '$SAMPLE.webp'; true" >/dev/null
ok "清理完成"

echo ""
echo "=== 2. 造一个样本 mp3（只为让扫描命令有东西可扫）==="
SZ=$(d "mkdir -p '$DD'; printf 'ID3\003\000\000\000\000\000\000fake' > '$MP3'; stat -c%s '$MP3'" | tr -d '\r' | tail -1)
if [ -n "$SZ" ] && [ "$SZ" -gt 0 ]; then ok "样本 mp3 已就位（$SZ 字节）"; else bade "样本 mp3 没建成（sz='$SZ'）"; fi

echo ""
echo "=== 3. 原样执行 buildCoverCmd 生成的命令 ==="
# ⛔ 判据只看**执行结果**：静态判断「引号对不对」是判不准的
d "$COVER_CMD" >/dev/null 2>&1 || true
sleep 3
ISIZE=$(d "stat -c%s '$SAMPLE$EXT' 2>/dev/null || echo 0" | tr -d ' \r')
if [ -n "$ISIZE" ] && [ "$ISIZE" -gt 1000 ]; then
    ok "封面已落盘：$SAMPLE$EXT（$ISIZE 字节）"
else
    bade "封面没落盘（size='$ISIZE'）"
fi
MAGIC=$(d "head -c 2 '$SAMPLE$EXT' 2>/dev/null | od -An -tx1 | tr -d ' \n\r'")
if [ "$MAGIC" = "ffd8" ]; then
    ok "文件头是 ff d8（真 JPEG，不是 404 的 JSON —— 那次踩过：URL 失效时网易云返回 177 字节的 {\"Code\":\"NoSuchKey\"}）"
else
    bade "文件头不是 JPEG：'$MAGIC'"
fi
PART=$(d "ls $TMPD/cover* 2>/dev/null | wc -l" | tr -d ' \r')
if [ "$PART" -eq 0 ]; then ok "临时 .part 已清掉（mv 成功不留残件）"; else bade "残留 $PART 个 cover .part"; fi

echo ""
echo "=== 4. 扫描命令认得出新封面 ==="
SCAN=$(d "$SCAN_CMD" 2>&1 || true)
SIDE=$(printf '%s\n' "$SCAN" | grep -c "^$MARKI" || true)
MUS=$(printf '%s\n' "$SCAN" | grep -c "^$MARKM" || true)
if [ "$SIDE" -ge 1 ]; then ok "扫描输出里有 $SIDE 行 sidecar 标记"; else bade "没扫到 sidecar 行"; printf '%s\n' "$SCAN"; fi
if [ "$MUS" -ge 1 ]; then ok "mp3 行仍正常（$MUS 行）—— 没被 sidecar 段破坏"; else bade "mp3 行不见了"; printf '%s\n' "$SCAN"; fi
FIRST=$(printf '%s\n' "$SCAN" | grep "^$MARKI" | head -1)
if [ -n "$FIRST" ] && [ "${FIRST#$MARKI}" != "$FIRST" ]; then
    ok "sidecar 行带标记前缀且内容是纯文件名：$FIRST"
else
    bade "sidecar 行格式不对：'$FIRST'"
fi

echo ""
echo "=== 5. 白名单：.webp 不该被扫成封面 ==="
d "printf 'x' > '$SAMPLE.webp'; true" >/dev/null
SCAN2=$(d "$SCAN_CMD" 2>&1 || true)
if printf '%s\n' "$SCAN2" | grep -q "^$MARKI.*\.webp"; then
    bade ".webp 被当成封面了（设备没有 webp 解码器，显示出来是空白）"
else
    ok ".webp 不进封面扫描（白名单生效）"
fi
d "rm -f '$SAMPLE.webp'; true" >/dev/null

echo ""
echo "=== 6. 失败路径：URL 无效时必须不留垃圾 ==="
# ⛔ 必须先删掉段 3 落下的封面再跑这一段。
#    段 6 验的是「下载失败 ⇒ 不产生 .jpg」，不是「下载失败 ⇒ 不覆盖已有 .jpg」——
#    早先版本忘了删，断言写成"不该留下 .jpg"，结果量到的是段 3 的合法产物，
#    探针自己红着脸false alarm。
d "rm -f '$SAMPLE.jpg' '$SAMPLE.png'; true" >/dev/null
# 只把 URL 换成不可达域名，命令的其余部分仍是真源码生成的那一条
BADC="$("$NODE" -e '
  const o = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))
  process.stdout.write(o.cover.replace(/https:\/\/[^\x27]+/, "https://invalid.invalid/x.jpg"))
' "$OUTJSON")"
d "$BADC" >/dev/null 2>&1 || true
sleep 3
LEFT=$(d "ls '$SAMPLE.jpg' '$SAMPLE.png' 2>/dev/null | wc -l" | tr -d ' \r')
if [ "$LEFT" -eq 0 ]; then ok "无效 URL 没有产生 .jpg/.png"; else bade "无效 URL 留下了 $LEFT 个图片文件"; fi
BADP=$(d "ls $TMPD/cover* 2>/dev/null | wc -l" | tr -d ' \r')
if [ "$BADP" -eq 0 ]; then ok "无效 URL 也没有残留 .part（rm -f 分支生效）"; else bade "残留 $BADP 个 .part"; fi

echo ""
echo "=== 7. 清理 ==="
d "rm -f '$MP3' '$SAMPLE.jpg' '$SAMPLE.png' '$SAMPLE.lrc' '$SAMPLE.webp'; true" >/dev/null
LEFT2=$(d "ls '$SAMPLE'* 2>/dev/null | wc -l" | tr -d ' \r')
if [ "$LEFT2" -eq 0 ]; then ok "样本已清理干净（不留孤儿文件在用户歌库里）"; else bade "还有 $LEFT2 个残留"; fi

# ---------------------------------------------------------------------------
echo ""
echo "=== 8. 闭环：真实歌库目录，真命令 → 真输出 → 真解析 → 与磁盘逐条核对 ==="
# 为什么前三层绿了还要这一层：
#   sidecar.sh          抠源码求值，但喂的是**手写**的理想 dump
#   sidecar-e2e (1~7)   命令真跑，但断言的是"文件有没有落盘"
#   sidecar-device.qml  真引擎，但喂的是**自己编的** dump
#   ⇒ 缺的一环：设备上**真实存在**的中文长文件名（带 、·… 这些字符）过一遍
#     真扫描 + 真解析，标记跟磁盘实际对不对得上。歌名带 shell 元字符时最容易翻车。
REAL_DUMP="$ROOT/.tmp/sidecar-real-dump.txt"
d "$SCAN_CMD" > "$REAL_DUMP" 2>/dev/null || true
if [ ! -s "$REAL_DUMP" ]; then
    bade "真实目录扫描输出为空（歌库是空的就跳过本段）"
else
    ok "扫到 $(grep -c . "$REAL_DUMP") 行真实输出"

    # 与设备 ls 出来的实际文件对照（这里必须用设备自己的答案，不能本地算）
    d "cd '$DD' && for f in *.mp3; do [ -e \"\$f\" ] || continue; echo \"M|\$f\"; done; for g in *.jpg *.png; do [ -e \"\$g\" ] || continue; echo \"I|\$g\"; done; for l in *.lrc; do [ -e \"\$l\" ] || continue; echo \"L|\$l\"; done; true" > "$ROOT/.tmp/sidecar-real-ls.txt" 2>/dev/null || true

    if "$NODE" "$ROOT/probe/sidecar-parse.js" "$QML" "$REAL_DUMP" "$ROOT/.tmp/sidecar-real-ls.txt"; then
        ok "真实输出能被真解析函数消化，且与磁盘实际一致（逐条核对见上）"
    else
        bade "真实输出解析/核对失败（见上）"
    fi
    rm -f "$ROOT/.tmp/sidecar-real-ls.txt"
fi
rm -f "$REAL_DUMP"

rm -f "$OUTJSON" "$ROOT/.tmp/sidecar-e2e-err.txt"

echo ""
echo "pass=$pass bad=$bad"
if [ "$bad" -gt 0 ]; then echo "FAIL ❌"; exit 1; fi
echo "PASS ✅ sidecar 命令 e2e 全过"
