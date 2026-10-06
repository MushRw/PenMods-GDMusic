#!/bin/bash
# 把 GD音乐插件推送到词典笔（纯 QML，无需编译）
set -euo pipefail

S="${ADB_SERIAL:-}"
[ -n "$S" ] || { echo "需要设备序列号：先跑 adb devices 查到，再 export ADB_SERIAL=<序列号>"; exit 1; }
P=/userdisk/PenMods/plugins/gdmusic
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && (pwd -W 2>/dev/null || pwd))"
L="$ROOT/plugin"
R="$ROOT"
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"

# 门禁：重复 property/function/id 声明检查。**必须在推之前**。
# 为什么需要它：这类错误（如 2026-10-03 的 `ncQrFile` 插了两遍）在真机 qmlscene
# 里报 "Duplicate property name" 直接让页面打不开，而 10 个源码探针**全绿** ——
# 它们只做字符串/求值断言，不解析 QML 结构。详见 tools/qml-dupdecl.js 头注释。
NODE="${NODE:-}"
[ -x "$NODE" ] || NODE=$(command -v node)
echo "--- 重复声明检查 ---"
# ⚠️ 必须用通配覆盖 qml/ 根目录，不能手写文件列表（2026-10-05 修）：
#   旧写法 `"$L/qml/main.qml" pages/*.qml components/*.qml` **漏掉 MediaBridge.qml** ——
#   而它恰恰是本门禁的由来文件：2026-10-03「整个插件页打不开」就是重复 property 声明，
#   而 MediaBridge.qml 在 qmldir 里是 **singleton**（qml/MediaBridge.qml:9-13 自承：
#   singleton 加载失败会让所有 import "." 的文件连坐 ⇒ 整个插件打不开）。
#   它还是最容易插重的文件：singleton 没有父对象，48 处属性自然全写在顶层。
#   ⇒ 这条门禁防的事故，事故文件本身却不在范围内。通配一劳永逸。
"$NODE" "$R/tools/qml-dupdecl.js" \
    "$L"/qml/*.qml "$L"/qml/pages/*.qml "$L"/qml/components/*.qml

# 门禁自己的自检。**必须挂在这里**，否则自检本身会腐化：
#   检查器的价值全在"抓到真事故"，而它上一版恰恰漏检了事故文件 MediaBridge.qml
#   （旧写法手写文件列表，漏了 qml/ 根目录）。一个从没被验证过的检查器，
#   它的"全绿"和"根本没跑"输出一样 —— 25 项合成夹具钉死"能抓到"与"不误报"。
echo "--- 门禁自检 ---"
# 自检里**故意**跑坏输入夹具（字面量通配符 / 不存在的文件），那两条 ❌ 会走 stderr。
# 直接透传会让部署者以为门禁挂了 ⇒ 只在真失败时才把它吐出来。
SELFLOG=/tmp/gdmusic_gate_selfcheck.log
if ! "$NODE" "$R/tools/test-qml-dupdecl.js" >"$SELFLOG" 2>&1; then
    echo "❌ 门禁自检失败（检查器本身可能已腐化）："
    cat "$SELFLOG"
    exit 1
fi
# reason 流自检：从 MediaBridge.qml **真源码**抠出 stopText/notifyFailure 求值，
# 钉住「失败提示只弹一次、user/end 不弹」。这类"每拍都判一次"的逻辑最容易
# 退化成每秒弹一次骚扰，或把用户主动停报成错误 —— 两者都只能靠求值断言防。
REASONLOG=/tmp/gdmusic_reason_selfcheck.log
if ! "$NODE" "$R/tools/test-reason-flow.js" >"$REASONLOG" 2>&1; then
    echo "❌ reason 流自检失败："
    cat "$REASONLOG"
    exit 1
fi

adb -s "$S" shell "rm -rf $P; mkdir -p $P/bin $P/qml/components $P/qml/pages"

# 推送用 find 驱动，**不要**再写硬编码列表：
# 之前硬编码漏掉了 bin/gdnext.lua，导致每次部署都把常驻播放器内核删掉，
# 症状是「本地明明有、刚推过，设备上却没有」，很难第一眼看出来。
pushed=0
while IFS= read -r rel; do
    # adb 会吞掉 while read 的 stdin，必须 < /dev/null，否则循环只跑第一轮
    adb -s "$S" push "$L/$rel" "$P/$rel" < /dev/null >/dev/null
    pushed=$((pushed + 1))
done < <(cd "$L" && find . -type f | sed 's|^\./||' | sort)
echo "已推送 $pushed 个文件"

# 权限：QML/元数据只需可读；gdipc.pl 必须可执行（插件用 shell 直接调用它）
adb -s "$S" shell "chmod -R a+rX $P; chmod 644 $P/metadata.json $P/icon.png; chmod 755 $P/bin/gdipc.pl"
echo "部署完成 -> $P"

# 一致性核对：逐个文件比 md5，抓「推了一半」/「忘了推」
echo "--- 本地 vs 设备 md5 ---"
drift=0
while IFS= read -r rel; do
    lm=$(md5sum "$L/$rel" | cut -d' ' -f1)
    # < /dev/null 必需：否则 adb 会吞掉 while read 的 stdin，循环只跑第一轮
    dm=$(adb -s "$S" shell "md5sum $P/$rel 2>/dev/null" < /dev/null | cut -d' ' -f1)
    if [ "$lm" = "$dm" ]; then
        printf '  ok   %s\n' "$rel"
    else
        printf '  DIFF %s  local=%s device=%s\n' "$rel" "$lm" "$dm"
        drift=1
    fi
done < <(cd "$L" && find . -type f | sed 's|^\./||' | sort)

[ "$drift" -eq 0 ] && echo "全部一致 ✅" || { echo "存在差异 ❌"; exit 1; }

# ---------------------------------------------------------------------------
# ⚠️ 清 QML 磁盘缓存 + 重启主程序 —— 两步都必做（踩过四次）
#
# 坑的形状：Qt 的 QML 缓存有三层，deploy 只清第一层等于没清：
#   1. 磁盘 .qmlc（本段清掉）
#   2. 主进程内存里的编译产物 —— **清了磁盘也没用**，引擎继续用内存里的
#      旧版本，症状同「没部署」一模一样（2026-10-01 22:3x 实测：缓存清空、
#      md5 全对、qmlscene 全绿，界面就是不变；killall 后 guardian 重拉才好）
#      ⇒ 必须 killall YoudaoDictPen 让 guardian 重拉（~5 秒，黑屏即回）
#   3. qrc 侧的缓存（PenMods 主程序的事，与本插件无关）
#
# 崩溃计数纪律：killall 会写 1 次退出计数（上电后第一次退出必然写 1，非崩溃）。
# 距上次退出 > 15s 就不累计，且 6 次才切槽 —— 一次部署 restart 无风险；
# 本脚本重启后会核对计数，异常增长则报警而不是静默清零。
#
# ---------------------------------------------------------------------------
# ⛔ 判据纠正（2026-10-02 实测）：**别再拿「.qmlc 里有新标识符」当判据**
#
#   本插件的 QML **不落独立磁盘缓存**。2026-10-02 全盘排查（find / -name '*.qmlc'
#   -newermt）确认：部署后**没有任何新写的 .qmlc**。
#   · /.cache/NeteaseYoudao/YoudaoDictPen/qmlcache  ← 宿主自己的 QML（91 个，会重生成）
#   · /userdata/PenMods/qmlcache                    ← 插件的旧档，最后修改 10-01 23:41，
#                                                     本次部署后**一个字节都没动**
#   所以在这个目录里 grep 'dlSidecar' 恒为 0 —— 它证明不了任何事（早先据此判"没生效"，
#   白查一轮）。插件走 qrc 资源 + 内存编译。
#
#   ✅ 真正的判据（按可信度排序）：
#   1. 设备上的 main.qml md5 == 本地（deploy 已逐个核对）
#   2. probe/sidecar-device.qml 在真机 qmlscene 里加载**设备上那份** main.qml 跑绿
#      —— 这直接证明运行中的 QML 引擎认得新代码，比翻缓存字符串强得多
#   3. 用户目视：界面元素真的变了
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--no-clearcache" ]; then
    echo "--- 已跳过清缓存与重启（--no-clearcache）---"
else
    C=/.cache/NeteaseYoudao/YoudaoDictPen/qmlcache
    BAK=/userdata/PenMods/qmlcache.bak-deploy
    # 两个目录都清：前者是宿主的，后者历史上是插件的。
    # 实测插件当前不往后者写（见上），但清它零成本，且省得哪天它又开始写时踩坑。
    PC=/userdata/PenMods/qmlcache
    PBAK=/userdata/PenMods/qmlcache.bak-deploy-plugin
    adb -s "$S" shell "rm -rf $BAK; cp -a $C $BAK 2>/dev/null; rm -rf $C; mkdir -p $C" < /dev/null
    adb -s "$S" shell "rm -rf $PBAK; cp -a $PC $PBAK 2>/dev/null; rm -rf $PC; mkdir -p $PC" < /dev/null
    n=$(adb -s "$S" shell "ls $C 2>/dev/null | wc -l" < /dev/null | tr -d ' \r')
    pn=$(adb -s "$S" shell "ls $PC 2>/dev/null | wc -l" < /dev/null | tr -d ' \r')
    echo "已清 QML 磁盘缓存：宿主 $C（现有 $n 个）、插件 $PC（现有 $pn 个）；备份 -> $BAK / $PBAK"

    # --- 重启主程序（否则第 2 层内存缓存还在用旧编译结果）---
    before=$(adb -s "$S" shell "cat /tmp/app_crash_count 2>/dev/null" < /dev/null | tr -d ' \r')
    adb -s "$S" shell "killall YoudaoDictPen 2>/dev/null" < /dev/null
    sleep 6
    pid=$(adb -s "$S" shell "pgrep -f '[Y]oudaoDictPen -platform' | head -1" < /dev/null | tr -d ' \r')
    after=$(adb -s "$S" shell "cat /tmp/app_crash_count 2>/dev/null" < /dev/null | tr -d ' \r')
    if [ -n "$pid" ]; then
        echo "主程序已重启（pid=$pid，guardian 重拉）"
    else
        echo "⚠️ 主程序 6 秒内未见重拉，请目视确认屏幕"
    fi
    echo "崩溃计数: $before -> $after （killall 写 1 次属预期；≥2 次才需要查）"
    echo "下次打开插件即按新源码编译 ✅"
fi
