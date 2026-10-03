#!/bin/sh
# gdnext.lua 「多歌手显示成 table: 0x...」修复的端到端验证
#
# 思路：lua 里的路径集中在 DIR 常量一处（QFILE/NFILE/LOGFILE 都由它拼出），
# 所以 sed 把 /tmp/gdmusic 换成 /tmp/gdtest 就能跑出一个完全隔离的实例，
# 不会动到用户正在播放的那个 mpv（它写的是 /tmp/gdmusic/now.json）。
#
# 做 A/B：同一份代码，把兜底那行改回 tostring(v) 作为对照组。
# 期望：修复组 artist = "歌手A,歌手B,歌手C"；对照组 artist = "table: 0x..."
#
# ⚠️ adb shell 派生的后台进程在会话结束时会被清掉，所以本脚本必须前台等待，
#    不能用 & 丢后台后立刻返回（那样测到的是"mpv 被清理"的假象）。

T=/tmp/gdtest
IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl
SRC=/userdisk/PenMods/plugins/gdmusic/bin/gdnext.lua
MPV=/userdisk/mpv/mpv

pass=0; fail=0
ck() { # ck 描述 判据
    if [ "$2" = "1" ]; then echo "  PASS  $1"; pass=$((pass+1))
    else echo "  FAIL  $1"; fail=$((fail+1)); fi
}

rm -rf "$T"; mkdir -p "$T"

# ---- 生成两个变体 ----
sed 's|/tmp/gdmusic|/tmp/gdtest|g; s|gdmusic\.lock|gdtest.lock|g' "$SRC" > "$T/gdnext_fixed.lua"
sed 's|(type(v) == "table") and flat(v) or tostring(v)|tostring(v)|' "$T/gdnext_fixed.lua" > "$T/gdnext_old.lua"

# 确认两个变体确实不同（否则 A/B 无意义）
if cmp -s "$T/gdnext_fixed.lua" "$T/gdnext_old.lua"; then
    echo "  FAIL  两个变体内容相同，无法 A/B"; exit 1
fi
echo "  PASS  A/B 两个变体已生成且确有差异"

# ---- 测试队列：歌手是数组（多歌手），这是本次 bug 的触发条件 ----
# 注意：刻意【不给 file 字段】，让它走联网取流分支 —— 那有几秒窗口，便于抢拍快照。
# 若给 file 且指向不存在的文件，失败流程是瞬时的，轮询根本抓不到中间态（踩过）。
cat > "$T/queue.json" <<'EOF'
{"source":"netease","quality":"320","autoNext":true,"index":1,
 "list":[{"id":"0","name":"测试歌名","artist":["歌手A","歌手B","歌手C"],
          "pic_id":"","lyric_id":""}]}
EOF

# ---- 跑一个变体，返回它写出的 artist ----
run_variant() {
    variant="$1"; sock="$T/$variant.sock"
    rm -f "$sock" "$T/now.json"
    nohup "$MPV" --no-video --force-window=no --idle=yes --keep-open=no \
          --input-ipc-server="$sock" --script="$T/gdnext_$variant.lua" \
          > "$T/mpv_$variant.log" 2>&1 &
    sleep 5
    # ⚠️ 必须【不带参数】：gdipc 的 cmd 模式会把裸数字发成 JSON 数字，
    #    而 mpv 的 script-message 遇到非字符串参数会**整条拒收**（静默）。
    #    本项目的约定就是 gd-load 不带参，要播第几首由 queue.json 的 index 决定。
    LC_ALL=C "$IPC" "$sock" cmd script-message gd-load >/dev/null 2>&1
    # 测试曲的 file 指向不存在的文件 ⇒ 几秒内就会走到「取不到流 → 顺延 → 停止」，
    # index 随即归 -1、字段清空。所以必须在推进过程中抢拍，不能 sleep 完再读。
    # play_index 一开始就同步写 now.json({status="loading"})，那一份就带着曲目信息。
    snap=""
    i=0
    while [ $i -lt 25 ]; do
        cur=$(cat "$T/now.json" 2>/dev/null)
        if echo "$cur" | grep -q '"index":1\.'; then snap="$cur"; break; fi
        i=$((i+1)); sleep 0.2
    done
    echo "$snap"
    pkill -f "[i]nput-ipc-server=$sock" 2>/dev/null
    sleep 1
    rm -f "$sock"
}

echo "=== 对照：修复前（tostring 版）==="
OLD=$(run_variant old)
echo "  now.json: $(echo "$OLD" | cut -c1-260)"
OLD_ARTIST=$(echo "$OLD" | sed -n 's/.*"artist":"\([^"]*\)".*/\1/p')

echo "=== 实验：修复后（flat 版）==="
NEW=$(run_variant fixed)
echo "  now.json: $(echo "$NEW" | cut -c1-260)"
NEW_ARTIST=$(echo "$NEW" | sed -n 's/.*"artist":"\([^"]*\)".*/\1/p')

echo
echo "=== 断言 ==="
[ -n "$OLD_ARTIST" ] && ck "对照组产出了 artist（测试有效）" 1 || ck "对照组产出了 artist（测试有效）" 0
echo "$OLD_ARTIST" | grep -q "^table: " && ck "复现 bug：对照组 artist = $OLD_ARTIST" 1 || ck "复现 bug：对照组 artist 应为 table: 地址，实为 [$OLD_ARTIST]" 0
[ -n "$NEW_ARTIST" ] && ck "修复组产出了 artist" 1 || ck "修复组产出了 artist" 0
echo "$NEW_ARTIST" | grep -q "^table: " && ck "修复组不再出现 table: 地址" 0 || ck "修复组不再出现 table: 地址（实为 [$NEW_ARTIST]）" 1
echo "$NEW_ARTIST" | grep -q "歌手A" && ck "修复组含第一位歌手" 1 || ck "修复组含第一位歌手" 0
echo "$NEW_ARTIST" | grep -q "歌手C" && ck "修复组含第三位歌手（数组未截断）" 1 || ck "修复组含第三位歌手（数组未截断）" 0
echo "$NEW_ARTIST" | grep -q "歌手A,歌手B,歌手C" && ck "修复组用逗号连接（与 QML 侧约定一致）" 1 || ck "修复组用逗号连接（与 QML 侧约定一致）" 0
echo "$NEW" | grep -q '"name":"测试歌名"' && ck "修复组歌名未被波及" 1 || ck "修复组歌名未被波及" 0

# ---- lua 脚本确实被加载且读到了测试队列（排除"脚本压根没跑"的假阳性）：
#     队列长度来自 queue.json，脚本没加载就不会是 1
echo "$NEW" | grep -q '"queueLen":1' && ck "lua 已加载并读到测试队列" 1 || ck "lua 已加载并读到测试队列" 0
if grep -qiE "attempt to|stack traceback|\[gdnext\]" "$T/mpv_fixed.log" 2>/dev/null; then
    ck "mpv 未报 lua 错误（见 $T/mpv_fixed.log）" 0
else
    ck "mpv 未报 lua 错误" 1
fi

# ---- 清理 ----
pkill -f "[i]nput-ipc-server=$T" 2>/dev/null
rm -f /tmp/audio_wakelocks/gdtest.lock
rm -rf "$T"

echo
echo "==== $pass PASS / $fail FAIL ===="
[ "$fail" = 0 ]
