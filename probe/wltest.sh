#!/bin/sh
# 唤醒锁闭环实测（**真机脚本**：需要设备，本机跑不了）
#
# ⚠️ 2026-10-05 修「假前提」。原来这文件的头注释声称：
#     「直接执行『插件 buildWakeLockCmd() 的原样输出』(/tmp/wakecmd.txt)」
# 实测（grep 全仓 probe/ tools/ plugin/）：
#     · `buildWakeLockCmd` **只在本文件自己的注释里**命中 —— 该函数**从未存在过**；
#     · `/tmp/wakecmd.txt` **没有任何脚本生成** —— 真机上 `sh /tmp/wakecmd.txt`
#       必然 "not found"，**整个探针等于没跑**，而且它照样打印 [PASS] 绿。
#     ⇒ 之前它测的不是插件生成的东西，是**人肉手抄的等价物**。
#
# 现在指向真实存在的 probe/wakecmd.sh。但**如实说明它是「离线等价件」**，
# 不是「原样输出」：
#     wakecmd.sh 用 `gdipc.pl <sock> pid` 轮询取 PID；
#     插件真实路径是 lua 的 acquire_lock()，在 mpv 进程内用
#     `mp.get_property_number("pid")`（gdnext.lua）。
#     两者取的是**同一个 PID**，但取法不同 ⇒ 这条探针验的是「锁能不能落、能不能放」，
#     **不**能证明 lua 那条取法没坏。lua 侧要单验，别拿这条顶替。
SOCK=/tmp/gdmusic.sock
LOCK=/tmp/audio_wakelocks/gdmusic.lock
STATE=/tmp/gdmusic
NOW=$STATE/now.json
PROBE_TXT=$STATE/probe.txt
IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl
# 被测命令：本文件同目录的 wakecmd.sh（相对定位，跟着文件走，不写死绝对路径）
WLCMD=$(dirname "$0")/wakecmd.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

if [ ! -f "$WLCMD" ]; then
    echo "❌ 找不到被测命令 $WLCMD"
    echo "   （这正是本文件原来的病：依赖一个谁都不生成的 /tmp/wakecmd.txt，"
    echo "     结果探针空跑却全绿。现在缺文件就直接失败，不再假装跑过。）"
    exit 2
fi

pkill -f '[i]nput-ipc-server='"$SOCK" 2>/dev/null
rm -f "$SOCK" "$LOCK" "$PROBE_TXT" "$NOW"; sleep 1

# ⚠️ 2026-10-05 补：killMpv 删四个目标，其中 probe.txt / now.json 由 mpv/插件在
# 真实播放时产生。但**本探针只起 idle mpv、从不播歌**，这两个文件不会被创建 ——
# 若直接断言「已清」，那就是恒真断言（文件压根不存在，检查器在演空戏）。
# ⇒ 这里先把它们造出来（内容与真路径同形：probe.txt 是 pid、now.json 是队列 JSON），
#    再断言收播时被 killMpv 的拷贝删掉。这样这条断言才真的在测东西。
mkdir -p "$STATE"
printf '12345\n' > "$PROBE_TXT"
printf '{"queue":[],"index":0}\n' > "$NOW"
[ -f "$PROBE_TXT" ] || bad "预置 probe.txt 失败（后面的清理断言会变恒真）"
[ -f "$NOW" ] || bad "预置 now.json 失败（后面的清理断言会变恒真）"

echo "== 启动 mpv =="
nohup /userdisk/mpv/mpv --no-video --force-window=no --idle=yes --volume=80 \
      --input-ipc-server="$SOCK" "https://music-api.gdstudio.xyz/api.php" >/tmp/wl_mpv.log 2>&1 &

echo "== 执行唤醒锁命令（$WLCMD，离线等价件） =="
sh "$WLCMD"
echo "  rc=$?"

echo "== 校验 =="
if [ -f "$LOCK" ]; then ok "锁文件已创建"; else bad "锁文件未创建"; fi
M=$(cat "$LOCK" 2>/dev/null)
echo "  锁内容(pid)=$M"
if [ -n "$M" ] && [ -d "/proc/$M" ]; then
    ok "锁内 PID 存活且 comm=$(cat /proc/$M/comm 2>/dev/null)"
else
    bad "锁内 PID 无效"
fi
# 交叉核对：mpv 自报的 pid 是否就是锁里那个
MP=$(LC_ALL=C "$IPC" "$SOCK" pid 2>/dev/null)
echo "  mpv 再报 pid=$MP"
[ "$M" = "$MP" ] && ok "锁 PID 与 mpv 自报一致" || bad "锁 PID 与 mpv 自报不一致"

# ⚠️ 2026-10-05 补：原版只删 $LOCK，而真实 killMpv()（MediaBridge.qml:594-600）
# 删的是**四个**目标：
#     rm -f $mpvSock $stateDir/probe.txt $wakeLockFile $nowFile
# 拷贝漏了三个 ⇒ mpv 真的被 kill 后，探针发现不了 sock/probe.txt/now.json 残留。
# 这三个残留不是洁癖：probe.txt 留着会让下一次 ensurePlayer 误判
# 「播放器还活着」而不重启它（MediaBridge.qml:592-593 的注释自承）。
# 下面是 killMpv 的**手工抄写**（QML 函数没法从 shell 直接调）。
# ⛔ 改了 MediaBridge.killMpv() 就要回来同步这一行 —— 它会腐化。
echo "== 收播：执行 killMpv 的手工拷贝（MediaBridge.qml:594-600） =="
sh -c "LC_ALL=C pkill -f '[i]nput-ipc-server=$SOCK' 2>/dev/null; \
       rm -f $SOCK $PROBE_TXT $LOCK $NOW; true"
sleep 1
[ -f "$LOCK" ] && bad "锁未释放" || ok "锁已释放"
# 新增三项：旧版根本没测，而它们恰恰是 killMpv 漏删就出事的地方。
# ⚠️ $SOCK 这条**不是恒真** —— 它由上面 `mpv --input-ipc-server=$SOCK` 真创建，
#    收播时没删干净就会被这里抓到。probe.txt / now.json 则由预置步骤保证存在。
[ -f "$SOCK" ]       && bad "socket 残留 $SOCK（下次 ensurePlayer 会误判播放器还活着）" || ok "socket 已清"
[ -f "$PROBE_TXT" ]  && bad "probe.txt 残留（下次 ensurePlayer 会误判播放器还活着）"    || ok "probe.txt 已清"
[ -f "$NOW" ]        && bad "now.json 残留"                                                || ok "now.json 已清"
pgrep -f '[i]nput-ipc-server='"$SOCK" >/dev/null 2>&1 && bad "mpv 仍在" || ok "mpv 已退出"

echo
echo "== 汇总 PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ] || exit 1
