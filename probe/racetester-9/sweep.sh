#!/bin/sh
# sweep.sh —— 在多个节拍下跑竞态，验证坏读率是否服从 P = W / T 模型
# 用法: sh sweep.sh <dur_s_per_run>
#
# 实测结果（30s/档）：2ms=50.8%、5ms=34.6%、20ms=46.5% —— **不单调**。
# 原因：写者与读者是【同周期】定时器，会相位锁死，不是独立的 W/T 随机对撞。
# ⇒ 本脚本的数字只能当「合成夹具标定」，不能代表真机 1Hz 场景。
D=/tmp/racetester-9
DUR=${1:-30}
for P in 2000 5000 20000; do
  sh $D/drive.sh "beat$P" "$DUR" "$P" "$P" 0 2>&1 | grep -Ev '^perl:'
  echo ""
done
