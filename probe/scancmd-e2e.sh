#!/bin/bash
# 端到端验证 buildScanCmd() —— **本地求值真实源码**拿到命令，推给设备执行，
# 再断言输出能被 parseLocalScan 消化。
#
# 为什么非要这么测（2026-10-02 的「本地页没歌」就是这么漏过去的）：
#   lstest/qmlcheck 这类探针喂进去的是**理想格式**的假输出（`@@GDMUS@@size|名字`），
#   于是 parseLocalScan 永远绿 —— 而真正的 bug 在**命令生成**这一侧：
#       echo '@@GDMUS@@'$(stat -c%s "$f")|$f
#   那个 `|` 没在引号内，被 /bin/sh 当成**管道符**（`|` 两边不加空格照样是管道），
#   等价于把 echo 的输出喂给一个名叫「歌曲名.mp3」的命令 ⇒ 必然 not found，
#   stdout 全空。而 ShellExecutor::exec() 只读 stdout、stderr 丢掉、exit code 也算成功
#   ⇒ 静默返回空 ⇒ 本地列表永远 0 首、界面只显示「还没有下载的歌」。
# 教训：**假数据只测解析，测不到拼接**。命令生成必须拿真源码去真设备上跑一趟。
set -euo pipefail

S="${ADB_SERIAL:-}"
[ -n "$S" ] || { echo "需要设备序列号：先跑 adb devices 查到，再 export ADB_SERIAL=<序列号>"; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && (pwd -W 2>/dev/null || pwd))"
QML="$ROOT/plugin/qml/main.qml"
NODE="${NODE:-}"
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"

[ -x "$NODE" ] || NODE=$(command -v node)

# ---- 1. 用 node 求值 main.qml 里的 buildScanCmd()，拿真实命令 ----
# 只截函数体（到 `\n    }` 之前）再补回右花括号，这样源码改了这个脚本自动跟上，
# 不会出现「脚本和实现各说各话」。
CMD=$("$NODE" - "$QML" <<'JS'
const fs = require('fs')
const src = fs.readFileSync(process.argv[2], 'utf8')
const i = src.indexOf('function buildScanCmd')
if (i < 0) { console.error('main.qml 里找不到 buildScanCmd'); process.exit(1) }
const end = src.indexOf('\n    }', i)
if (end < 0) { console.error('buildScanCmd 函数体截取失败'); process.exit(1) }
const body = src.slice(i, end) + '\n}'
function readStr(re, what) {
    const m = src.match(re)
    if (!m) { console.error('读不到 ' + what + '（main.qml 里的属性名/引号形式变了？）'); process.exit(1) }
    return m[1]
}
// ⛔ 常量一律**从 main.qml 读**，不硬编码：buildScanCmd 增删依赖（sidecar 段加了
//    sidecarMark / lrcMark）时，硬编码的桩环境会直接 ReferenceError。
//    症状是探针"坏了"而不是"实现坏了"，很容易误判成回归。
const downloadDir = readStr(/readonly property string downloadDir:\s*"([^"]+)"/, 'downloadDir')
const localMark   = readStr(/readonly property string localMark:\s*"([^"]+)"/, 'localMark')
const sidecarMark = readStr(/readonly property string sidecarMark:\s*"([^"]+)"/, 'sidecarMark')
const lrcMark     = readStr(/readonly property string lrcMark:\s*"([^"]+)"/, 'lrcMark')
const shellQuote = (s) => "'" + String(s).replace(/'/g, "'\\''") + "'"
const f = new Function('downloadDir', 'localMark', 'sidecarMark', 'lrcMark', 'shellQuote',
                       body + '\nreturn buildScanCmd()')
process.stdout.write(f(downloadDir, localMark, sidecarMark, lrcMark, shellQuote))
JS
)

echo "--- 生成的命令 ---"
printf '%s\n' "$CMD"
echo "------------------"

# ---- 2. 在设备上跑 ----
# 判据**只看执行结果**：想静态判断「| 有没有落在引号内」是判不准的
# （`$(stat … "…")|` 里的那个 ')' 会把粗正则骗成"管道符裸露"），
# 而"一行都扫不到"是毫无歧义的真信号。stderr 也一起收，好让对方看见 not found。
OUT=$(adb -s "$S" shell "$CMD" 2>&1 || true)
n=$(printf '%s\n' "$OUT" | grep -c '^@@GDMUS@@' || true)
mp3=$(adb -s "$S" shell "ls /userdisk/Music/GDMusic/*.mp3 2>/dev/null | wc -l" | tr -d ' \r')

echo "扫描到 $n 行，设备上 mp3 实际 $mp3 个"
if [ "$n" -eq 0 ]; then
    echo "FAIL ❌ 一行都没扫到 —— 命令生成有问题（stdout 空会被 exec() 静默吞掉）"
    echo "设备原始输出："; printf '%s\n' "$OUT"
    if printf '%s' "$OUT" | grep -qE 'not found|Broken pipe'; then
        echo "👉 「not found / Broken pipe」= 分隔符 | 被 /bin/sh 当成了**管道符**："
        echo "   把整段 echo 的参数包进双引号（见 buildScanCmd 上方注释）。"
    fi
    exit 1
fi
if [ "$n" -ne "$mp3" ]; then
    echo "FAIL ❌ 行数与文件数不符"
    printf '%s\n' "$OUT"
    exit 1
fi
echo "PASS ✅ buildScanCmd 的输出可被 parseLocalScan 消化"
