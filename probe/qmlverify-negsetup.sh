#!/bin/bash
# 阴性对照搭建（**在主机上跑**，通过 adb 操作设备）：
# 在设备工作目录下做两份**故意的坏副本**，验证「singleton 加载失败」这条路
# 真的能被 qmlscene 看见（否则 PASS 就不能排除「探针根本测不到」）。
#
# 用法：bash qmlverify-negsetup.sh <序列号> [工作目录]
# ⚠️ 只读源目录 /userdisk/PenMods/plugins/gdmusic/，所有写入都在工作目录下。
set -euo pipefail

S="${1:?需要设备序列号}"
WORK="${2:-/tmp/qmlverify}"
SRC=/userdisk/PenMods/plugins/gdmusic/qml
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"

sh_dev() { adb -s "$S" shell "$1" 2>&1 | tr -d '\r'; }

sh_dev "rm -rf $WORK/negA $WORK/negB; mkdir -p $WORK/negA $WORK/negB"
sh_dev "cp -r $SRC/. $WORK/negA/"
sh_dev "cp -r $SRC/. $WORK/negB/"

# negA：剥掉 pragma Singleton（qmldir 仍声明 singleton）
sh_dev "sed -i '/^pragma Singleton/d' $WORK/negA/MediaBridge.qml"
echo "  negA MediaBridge.qml 前 4 行："
sh_dev "head -4 $WORK/negA/MediaBridge.qml" | sed 's/^/    /'

# negB：制造语法错误
sh_dev "printf '\nthis is not valid qml @@@\n' >> $WORK/negB/MediaBridge.qml"
echo "  negB MediaBridge.qml 末 3 行："
sh_dev "tail -3 $WORK/negB/MediaBridge.qml" | sed 's/^/    /'

echo "  阴性对照已就绪于 $WORK/negA 与 $WORK/negB"
