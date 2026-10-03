#!/usr/bin/env bash
# 远程截屏通道 · 源码求值层
#
# 两条通道共用哨兵 /tmp/penmods_shot：
#   ① C++ ScreenGrabber  → QQuickWindow::grabWindow()，任意页面可截
#   ② 插件 QML grabShot() → Item.grabToImage()，插件页局部（旋转已转正）
# 这一层只做**源码静态断言**（不跑真机、不碰 shell）：抓图通道静默失效的典型原因
# 全是「名字被改掉 / 回调写错 / Timer 不 running」，纯看代码就能拦住。
set -uo pipefail
cd "$(dirname "$0")/.."
QML=plugin/qml/main.qml
SG=../PenMods/src/system/input/ScreenGrabber.cpp
pass=0; bad=0
# ok <实际值> <期望值> <描述>
ok()  { if [ "$1" = "$2" ]; then pass=$((pass+1)); echo "  ok   $3"; else bad=$((bad+1)); echo "  FAIL $3 (得到 '$1'，期望 '$2')"; fi; }
# 有 <描述>：grep -q 命中即过
has() { if grep -q "$1" "$2"; then pass=$((pass+1)); echo "  ok   $3"; else bad=$((bad+1)); echo "  FAIL $3 (找不到 /$1/ 于 $2)"; fi; }
# 无 <描述>：grep -q 未命中即过
hasnt(){ if grep -q "$1" "$2"; then bad=$((bad+1)); echo "  FAIL $3 (仍存在 /$1/)"; else pass=$((pass+1)); echo "  ok   $3"; fi; }

echo "=== A. 哨兵路径（两条通道必须同名，否则一个 touch 覆盖不到）==="
has 'shotReq: *"/tmp/penmods_shot"'      $QML "QML 侧哨兵是 /tmp/penmods_shot"
has 'kReq  *= *"/tmp/penmods_shot"'        $SG "C++ 侧哨兵是 /tmp/penmods_shot"
# 哨兵错名 = 通道静默失效且没有任何症状，最难查，所以写死断言
hasnt 'gdmusic_shot'                     $QML "QML 里不再残留旧的 gdmusic_shot 命名"
has   'shotOut: *"/tmp/penmods_gd_shot"'  $QML "QML 输出名与 C++ 的 penmods_shot-N 区分（避免抢同一文件）"

echo "=== B. QML 抓图实现 ==="
has 'function grabShot'                  $QML "有 grabShot()"
has 'root.grabToImage('                  $QML "调的是 root.grabToImage()"
# grabToImage 是异步的：saveToFile 必须在回调里，挪到外面就抓不到
has 'grabToImage(function'               $QML "grabToImage 传的是回调（异步）"
has 'saveToFile'                         $QML "回调里调 saveToFile"
has 'res.destroy()'                      $QML "回调结束 destroy 抓图结果（否则每帧泄漏）"
has 'shotBusy'                           $QML "有防重入标志 shotBusy"
if [ "$(grep -c 'shotBusy = true' $QML)" -ge 1 ] && [ "$(grep -c 'shotBusy = false' $QML)" -ge 1 ]; then
    pass=$((pass+1)); echo "  ok   shotBusy 置位与释放成对"
else bad=$((bad+1)); echo "  FAIL shotBusy 置位/释放不成对（会永久卡死不再抓图）"; fi

echo "=== C. QML 触发回路 ==="
has 'id: shotPollTimer'                  $QML "有 shotPollTimer"
# running 必须绑 visible：插件页不在前台时轮询是纯浪费
has 'running: root.visible'              $QML "Timer running 绑 root.visible（不在前台不轮询）"
has 'test -f " + root.shotReq'           $QML "用 test -f 判哨兵"
# 先删哨兵再抓，否则回调返回前会再命中一次，连抓十几张同样的图
has 'rm -f " + root.shotReq'             $QML "抓图前先删哨兵（防重复触发）"
has 'root.grabShot()'                    $QML "命中后调 grabShot()"

echo "=== D. 失败原因可观测（抓不到图最容易被误判成「设备不给截」）==="
has 'grab-nores'                         $QML "无结果对象时写 grab-nores"
has 'ok ? "ok " : "fail "'                $QML "区分 ok / fail 落盘结果"
has 'shotLog'                            $QML "结果日志路径 shotLog 贯穿"

echo "=== E. C++ 侧关键防线 ==="
has 'grabWindow()'                       $SG "走 QQuickWindow::grabWindow()"
# 设备若没编 PNG 编码器，save() 返回 false 写出 0 字节文件 —— 症状与「抓不到」一模一样
has 'supportedImageFormats'              $SG "显式检查 PNG 编码器存在"
has 'no-png-enc'                         $SG "PNG 编码器缺失有独立错误码"
has 'QThread::currentThread'             $SG "校验在 GUI 线程（grabWindow 跨线程会静默失败）"
has 'grab-null'                          $SG "窗口未 exposed 时有独立错误码"
has 'wrong-thread'                       $SG "线程不符有独立错误码"
has 'beforeUiInitialization'             $SG "从 beforeUiInitialization 拿常驻 view"
has 'QFile::remove'                      $SG "C++ 侧也先删哨兵"
has 'isExposed'                          $SG "记录 exposed 状态（区分「窗口不可见」与「抓图失败」）"

echo ""
echo "pass=$pass bad=$bad"
[ "$bad" -eq 0 ] || exit 1
