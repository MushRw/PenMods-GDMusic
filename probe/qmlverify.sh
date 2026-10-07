#!/bin/bash
# ============================================================================
# 真机 QML 加载验证（qmlverifier / task-8）
#
# 用法（Git Bash / MSYS）：
#   export ADB_SERIAL=2AB2900000800514
#   bash probe/qmlverify.sh
#
# 只读设备：不碰 /userdisk/PenMods/plugins/gdmusic/、不 killall、不 reboot、不跑 deploy.sh。
# 所有写入都在设备 /tmp/qmlverify/ 下，脚本结束时自动清理。
#
# ⚠️ 前提：设备上部署的**未必**是本地 HEAD。本脚本先做版本指纹比对，
#    并明确报告「实测的是哪一版」，避免把旧版结果当新版通过。
#
# 退出码：0 = 全部探针通过；1 = 有探针失败。
#   版本指纹不一致只作为 NOTICE 报告（它描述环境，不是探针失败），
#   但会在结论里显式警告「本次结论只代表设备上那一版」。
# ============================================================================
set -uo pipefail

S="${ADB_SERIAL:-}"
[ -n "$S" ] || { echo "需要设备序列号：export ADB_SERIAL=<序列号>（先跑 adb devices 查）"; exit 1; }

HERE_U="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # unix 路径（给 bash/ls 用）
HERE_W="$(cd "$(dirname "${BASH_SOURCE[0]}")" && (pwd -W 2>/dev/null || pwd))"  # Windows 路径（给 adb 用）
ROOT_W="$(cd "$HERE_U/.." && (pwd -W 2>/dev/null || pwd))"
DEV_PLUGIN=/userdisk/PenMods/plugins/gdmusic
WORK=/tmp/qmlverify
# ⚠️ MSYS_NO_PATHCONV=1 时 adb 不会把 /tmp/... 转成 Windows 路径，
#    但**源文件路径必须是 Windows 形式**，否则 adb 报 cannot stat。
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"

PASS=0; FAIL=0; NOTICE=0
ok()   { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
note() { NOTICE=$((NOTICE+1)); echo "  [NOTE] $1"; }

sh_dev() { adb -s "$S" shell "$1" 2>&1 | tr -d '\r'; }

echo "============================================================"
echo " 0. 设备事实（只读）"
echo "============================================================"
sh_dev "uname -a" | sed 's/^/  /'
echo "  qmlscene: $(sh_dev 'ls -l /usr/bin/qmlscene' | head -1)"
QTVER="$(sh_dev "cd /tmp && QT_QPA_PLATFORM=offscreen /usr/bin/qmlscene /dev/null 2>&1 | grep -o 'Qt version [0-9.]*' | head -1")"
echo "  Qt: ${QTVER:-（未能从 qmlscene 直接取到版本）}"

echo
echo "============================================================"
echo " 1. 版本指纹：设备上部署的到底是哪一版？"
echo "============================================================"
DEVMD5="$(sh_dev "cd $DEV_PLUGIN && md5sum qml/main.qml qml/MediaBridge.qml qml/qmldir qml/Theme.qml bin/gdnext.lua metadata.json")"
echo "$DEVMD5" | sed 's/^/  /'
MB_DEV="$(echo "$DEVMD5" | awk '/MediaBridge/ {print $1}')"
echo "  设备 MediaBridge.qml md5 = $MB_DEV"
if command -v git >/dev/null 2>&1 && [ -d "$ROOT_W/.git" ]; then
  MB_HEAD="$(git -C "$ROOT_W" cat-file blob HEAD:plugin/qml/MediaBridge.qml 2>/dev/null | md5sum | awk '{print $1}')"
  echo "  本地 HEAD MediaBridge.qml md5 = $MB_HEAD"
  if [ -n "$MB_HEAD" ] && [ "$MB_DEV" = "$MB_HEAD" ]; then
    ok "设备部署版与本地 HEAD 一致（本次结论可代表 HEAD）"
  else
    note "设备部署版与本地 HEAD **不一致**"
    echo "         ⇒ 下面所有结果只代表**设备上那一版**，不能当作 HEAD 的验证结论。"
  fi
else
  note "跳过 HEAD 比对（git 不可用或非仓库）"
fi

echo
echo "============================================================"
echo " 2. 推送探针（只往 $WORK 推）"
echo "============================================================"
sh_dev "mkdir -p $WORK"
PUSHED=0; EXPECT=10
for f in qmlcheck.qml \
         qmlverify-singleton.qml \
         qmlverify-arity.qml \
         qmlverify-defaultarg.qml \
         qmlverify-signal.qml \
         qmlverify-fn-vs-signal.qml \
         qmlverify-toast-arity.qml \
         qmlverify-e2e-toast.qml \
         qmlverify-neg-nopragma.qml \
         qmlverify-neg-syntax.qml ; do
  if adb -s "$S" push "$HERE_W/$f" "$WORK/$f" >/dev/null 2>&1; then
    echo "  pushed $f"; PUSHED=$((PUSHED+1))
  else
    echo "  !! push 失败 $f"
  fi
done
[ "$PUSHED" -eq "$EXPECT" ] && ok "$EXPECT 个探针全部推送成功" || bad "只有 $PUSHED/$EXPECT 个探针推送成功"

# ⚠️ 必须在**设备上**跑 qmlscene（主机没有 Qt 工具链）。
#    早先版本漏了 adb shell，导致在主机上执行 /usr/bin/qmlscene ⇒
#    "failed to run command ... No such file or directory"，且各段全 FAIL。
run_qml() { sh_dev "cd /tmp && QT_QPA_PLATFORM=offscreen timeout ${2:-60} /usr/bin/qmlscene $WORK/$1"; }

echo
echo "============================================================"
echo " 3. 既有探针 qmlcheck.qml（加载 main.qml + 跑断言）"
echo "============================================================"
QC="$(run_qml qmlcheck.qml 40)"
QC_N=$(printf '%s\n' "$QC" | wc -l)
QC_CHK=$(printf '%s\n' "$QC" | grep -c 'qml: CHK ' || true)
echo "  输出行数=$QC_N  CHK 行数=$QC_CHK"
# ⚠️ 必须先确认「真的跑起来了」再判绿 —— 否则空输出会被当成「零警告」的假绿。
if [ "$QC_CHK" -lt 10 ]; then
  bad "qmlcheck 没跑起来（CHK 行数=$QC_CHK < 10）⇒ 后续「零警告」判定无效"
  printf '%s\n' "$QC" | head -5 | sed 's/^/      /'
else
  ok "qmlcheck 真的执行了（CHK 行数=$QC_CHK）"
  if printf '%s\n' "$QC" | grep -q 'CHK LOAD-ERROR'; then
    bad "main.qml 加载失败（CHK LOAD-ERROR）"
  else
    ok "main.qml 加载成功（无 CHK LOAD-ERROR）"
  fi
  WARN="$(printf '%s\n' "$QC" | grep -E 'Error:|Unable to assign|TypeError|ReferenceError|is not a function|Cannot read propert|QML (Debug|Warning)|Assertion failed|Type .* unavailable' || true)"
  if [ -n "$WARN" ]; then
    bad "加载期出现警告/错误："; printf '%s\n' "$WARN" | sed 's/^/      /'
  else
    ok "加载期零 QML 警告/错误"
  fi
fi

echo
echo "============================================================"
echo " 4. 🔴 核心：MediaBridge singleton 独立加载"
echo "============================================================"
SG="$(run_qml qmlverify-singleton.qml 60)"
printf '%s\n' "$SG" | grep 'QV ' | sed 's/^/  /'
SGR="$(printf '%s\n' "$SG" | grep 'QV RESULT' || true)"
if printf '%s\n' "$SGR" | grep -q 'bad=0' && printf '%s\n' "$SGR" | grep -q 'pass='; then
  ok "MediaBridge singleton 独立加载通过（$SGR）"
else
  bad "MediaBridge singleton 加载有问题（$SGR）"
fi
if printf '%s\n' "$SG" | grep -q 'Type MediaBridge unavailable'; then
  bad "出现 Type MediaBridge unavailable（整个插件会连坐打不开）"
fi

echo
echo "============================================================"
echo " 5. 实参个数机制（用 Qt 自带带默认参数的 Q_INVOKABLE 对照）"
echo "============================================================"
AR="$(run_qml qmlverify-arity.qml 60)"
printf '%s\n' "$AR" | grep -E 'AR2 (CALL|PASS|FAIL|SUMMARY|CONCLUSION|RESULT|NOTE)' | sed 's/^/  /'
printf '%s\n' "$AR" | grep -q 'AR2 CONCLUSION' && ok "机制探针已给出结论" || bad "机制探针未给出结论"
FA="$(run_qml qmlverify-defaultarg.qml 60)"
printf '%s\n' "$FA" | grep -E 'FOC (CALL|PASS|FAIL|RESULT)' | sed 's/^/  /'
printf '%s\n' "$FA" | grep -q 'FOC RESULT pass=.*bad=0' && ok "默认值语义探针通过" || bad "默认值语义探针有失败"

echo
echo "============================================================"
echo " 6. showToast 的真实形态（信号）+ 少传实参的后果"
echo "============================================================"
SI="$(run_qml qmlverify-signal.qml 60)"
printf '%s\n' "$SI" | grep -E 'SG ' | sed 's/^/  /'
if printf '%s\n' "$SI" | grep -q 'SG RESULT pass=.*bad=0'; then
  ok "信号少传实参行为已实测确认"
else
  bad "信号探针有失败项"
fi
# 6b. 三种可调用对象分开测 —— 回答「QML 函数少传只得到 undefined（不抛）」与
#     「QML 信号少传会抛」的区别，避免把两者混为一谈。
FN="$(run_qml qmlverify-fn-vs-signal.qml 60)"
printf '%s\n' "$FN" | grep -E 'FN (CALL|PASS|FAIL|CONCLUSION|RESULT)' | sed 's/^/  /'
if printf '%s\n' "$FN" | grep -q 'QML函数少传抛错=false' \
   && printf '%s\n' "$FN" | grep -q 'QML信号少传抛错=true' \
   && printf '%s\n' "$FN" | grep -q 'C++方法少传抛错=true'; then
  ok "已区分：QML 函数少传→undefined 不抛；QML 信号少传→抛；C++ 方法少传→抛"
else
  bad "函数/信号/方法 少传实参行为未达预期"
fi

echo
echo "============================================================"
echo " 7. 严格夹具：设备上 MediaBridge 的 showToast 实参个数"
echo "============================================================"
TO="$(run_qml qmlverify-toast-arity.qml 60)"
printf '%s\n' "$TO" | grep -E 'TO (CALL|PASS|FAIL|SUMMARY|CONCLUSION|RESULT)' | sed 's/^/  /'
if printf '%s\n' "$TO" | grep -q 'TO CONCLUSION'; then
  ok "实参个数探针已给出结论"
  # ⚠️ 这条探针在**未修复版**上本来就该是红的（bad>0）。
  #    它的价值是「能区分两版」，不是「必须全绿」——别把它当门禁。
  if printf '%s\n' "$TO" | grep -q 'TO CONCLUSION.*都传满 2 个实参'; then
    ok "设备上部署版已传满 2 个实参（该修复已在设备上生效）"
  else
    note "设备上部署版仍是单实参调用（该修复尚未部署到设备）—— 这是预期的红，不是探针故障"
  fi
else
  bad "实参个数探针未给出结论"
fi
echo
echo "  端到端（真实失败路径 → toast 是否到用户眼前）："
E2E="$(run_qml qmlverify-e2e-toast.qml 60)"
printf '%s\n' "$E2E" | grep -E 'E2E ' | sed 's/^/  /'
if printf '%s\n' "$E2E" | grep -q 'E2E SUMMARY'; then
  ok "端到端探针已给出结论"
  # ⚠️ 必须只匹配 **E2E SUMMARY 那一行**，不能在整个输出里 grep 'toastCount=0'。
  #    2026-10-07 踩过：夹具自检行里有一句
  #      `E2E PASS 夹具自检 真实信号单实参抛错且处理器未调用（toastCount=0）`
  #    —— 那是**故意构造的失败对照**（证明夹具能判失败），不是本次结果。
  #    旧写法 grep 全文 ⇒ 在已修复的部署上也误报「缺陷存在」，把绿的说成红的。
  #    （这与本项目反复治的「断言匹配面太宽 ⇒ 假绿/假红」是同一类病。）
  E2E_SUM="$(printf '%s\n' "$E2E" | grep 'E2E SUMMARY' | tail -1)"
  if printf '%s' "$E2E_SUM" | grep -q 'toastCount=0'; then
    note "设备上部署版：失败提示**没有**到达用户（$E2E_SUM，异常被 catch 吞掉）—— 即该缺陷在设备上真实存在"
  else
    ok "设备上部署版：失败提示能到达用户（$E2E_SUM）"
  fi
else
  bad "端到端探针未给出结论"
fi

# ---- 7b. 差分对照：同一份夹具对 HEAD 版跑，证明它「能区分两版」----
# 只在设备部署版 ≠ HEAD 时才有意义（否则两者相同，差分无信息）。
if [ -n "${MB_HEAD:-}" ] && [ "$MB_DEV" != "$MB_HEAD" ]; then
  echo
  echo "  7b. 差分对照：同一份夹具对 **HEAD 修复版** 跑（副本放 $WORK/headqml，不动设备插件）"
  HEADMB_U=/tmp/qv-head-mb.qml
  if git -C "$ROOT_W" cat-file blob HEAD:plugin/qml/MediaBridge.qml > "$HEADMB_U" 2>/dev/null \
     && bash "$HERE_U/qmlverify-headsetup.sh" "$S" "$WORK" "$HEADMB_U"; then
    # 生成 HEAD 变体探针：只替换 import 路径
    sh_dev "cd $WORK && sed 's|file:///userdisk/PenMods/plugins/gdmusic/qml|file://$WORK/headqml|' qmlverify-toast-arity.qml > qv-head-arity.qml && sed 's|file:///userdisk/PenMods/plugins/gdmusic/qml|file://$WORK/headqml|' qmlverify-e2e-toast.qml > qv-head-e2e.qml"
    TOH="$(run_qml qv-head-arity.qml 60)"
    printf '%s\n' "$TOH" | grep -E 'TO (SUMMARY|CONCLUSION|RESULT)' | sed 's/^/    /'
    E2EH="$(run_qml qv-head-e2e.qml 60)"
    printf '%s\n' "$E2EH" | grep -E 'E2E (RESULT|SUMMARY)' | sed 's/^/    /'
    if printf '%s\n' "$TOH" | grep -q '全部传满2=true' && printf '%s\n' "$E2EH" | grep -q 'toastCount=1'; then
      ok "差分成立：旧版 [1,1,1]/toastCount=0，HEAD 版 [2,2,2]/toastCount=1 ⇒ 夹具能区分两版，非恒真非恒假"
    else
      bad "差分不成立：夹具未能区分旧版与 HEAD 版"
    fi
  else
    note "差分对照搭建失败（跳过）"
  fi
fi

echo
echo "============================================================"
echo " 8. 阴性对照：MediaBridge 加载失败这条路可复现吗？"
echo "============================================================"
if bash "$HERE_U/qmlverify-negsetup.sh" "$S" "$WORK" >/dev/null 2>&1; then
  echo "  negA / negB 坏副本已就绪"
else
  echo "  !! 阴性对照搭建失败"
fi
NEGA="$(run_qml qmlverify-neg-nopragma.qml 40)"
NEGB="$(run_qml qmlverify-neg-syntax.qml 40)"
echo "  --- 阴性对照 A（剥掉 pragma Singleton）---"
printf '%s\n' "$NEGA" | grep -E 'unavailable|pragma Singleton|Syntax' | sed 's/^/    /'
printf '%s\n' "$NEGA" | grep -q 'Type MediaBridge unavailable' \
  && ok "对照A 复现了 Type MediaBridge unavailable" \
  || bad "对照A 没能复现 unavailable（说明本探针测不到加载失败）"
echo "  --- 阴性对照 B（语法错误）---"
printf '%s\n' "$NEGB" | grep -E 'unavailable|Syntax' | sed 's/^/    /'
printf '%s\n' "$NEGB" | grep -q 'Type MediaBridge unavailable' \
  && ok "对照B 复现了 Type MediaBridge unavailable" \
  || bad "对照B 没能复现 unavailable"

echo
echo "============================================================"
echo " 9. 清理设备临时文件（只删自己建的 $WORK）"
echo "============================================================"
sh_dev "rm -rf $WORK; ls -d $WORK 2>/dev/null && echo STILL-THERE || echo removed"
echo "  设备插件目录复核（应与开始时一致）："
sh_dev "cd $DEV_PLUGIN && md5sum qml/MediaBridge.qml qml/main.qml"
MB_AFTER="$(sh_dev "cd $DEV_PLUGIN && md5sum qml/MediaBridge.qml" | awk '{print $1}')"
[ "$MB_AFTER" = "$MB_DEV" ] && ok "设备插件未被本次验证改动" || bad "设备插件 md5 变了！"

echo
echo "============================================================"
echo " 结果: PASS=$PASS FAIL=$FAIL NOTICE=$NOTICE"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
