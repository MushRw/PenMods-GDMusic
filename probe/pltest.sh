#!/bin/sh
# ============================================================
# ⚠️ NOT-A-TEST —— 这是**诊断打印件**，不是断言件。
#
# 本文件只 echo 观察结果，没有 pass/bad 判定，也**不会**因为失败而返回非 0。
# ⇒ 它的"绿"不构成任何回归保护，别把它当门禁看。
#
# 2026-10-05 标注：探针目录里"真断言件"与"诊断打印件"混在一起，
# 新人看到满屏 ✅ 就以为验过了 —— 而这一类压根没有 ✅。
# 真断言件长这样：有 pass/bad 计数、结尾 `exit 1`、输出被别的 .sh grep
# （例：addpick-device.sh:47 `grep -q "bad=0"`、login-device.sh:39、
#       sidecar-e2e.sh 的 ok/bade 体系）。
# 判定脚本想变断言件：加 bad 计数 + 结尾 `exit $bad`，别只改文案。
# 详细清单见 audit-report/gdmusic-probe-ref.md 第一节 C。
# ============================================================
# 验证 mpv 原生 playlist 能否替代「我自己写的 idle 判结束 + 换 url」逻辑
# 若成立 => 退出插件后 mpv 自己就能顺序播完整个队列（真正的后台连播）
API="https://music-api.gdstudio.xyz/api.php"
IPS="104.18.0.1 104.17.0.1 104.19.0.1 104.20.0.1 104.16.0.1"
SOCK=/tmp/pl.sock
IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl

api() {
  for ip in $IPS; do
    r=$(LC_ALL=C curl -s --max-time 6 -A 'Mozilla/5.0' \
        --resolve music-api.gdstudio.xyz:443:$ip "$API?$1" 2>/dev/null)
    case "$r" in "["*|"{"*) printf '%s' "$r"; return 0;; esac
  done
  printf '%s' "$r"
}

echo "== 1. 搜索拿 id =="
S=$(api "types=search&source=netease&name=%E5%91%A8%E6%9D%B0%E4%BC%A6&count=6&pages=1")
IDS=$(printf '%s' "$S" | tr ',' '\n' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -6)
echo "  候选 id: $(echo $IDS | tr '\n' ' ')"

echo "== 2. 逐个取 url（最多要 3 个成功）=="
URLS=""
N=0
for id in $IDS; do
  J=$(api "types=url&source=netease&id=$id&br=320")
  U=$(printf '%s' "$J" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
  case "$U" in
    http*) URLS="$URLS $U"; N=$((N+1)); echo "   id=$id -> OK";;
    *) echo "   id=$id -> 无 url";;
  esac
  [ $N -ge 3 ] && break
done
[ $N -lt 2 ] && { echo "FETCH_FAIL 取不到足够 url，测试中止"; exit 1; }

echo
echo "== 3. 启动 mpv（多 url 作为 playlist，注意：不加 --idle）=="
pkill -f "[i]nput-ipc-server=$SOCK" 2>/dev/null; rm -f $SOCK
# shellcheck disable=SC2086
nohup /userdisk/mpv/mpv --no-video --force-window=no --keep-open=no --volume=80 \
      --input-ipc-server=$SOCK $URLS >/tmp/pl.log 2>&1 &
i=0; while [ $i -lt 40 ]; do [ -S $SOCK ] && break; i=$((i+1)); sleep 0.25; done
sleep 3

echo "== 4. playlist 结构 =="
for p in playlist-count playlist-pos media-title; do
  printf "   %-16s = %s\n" "$p" "$(LC_ALL=C $IPC $SOCK raw "{\"command\":[\"get_property\",\"$p\"],\"request_id\":1}" 2>/dev/null | tail -1)"
done

echo
echo "== 5. 跳到第一首结尾，看是否自动前进到第二首 =="
D=$(LC_ALL=C $IPC $SOCK raw '{"command":["get_property","duration"],"request_id":1}' 2>/dev/null | tail -1 | sed -n 's/.*"data":\([0-9.]*\).*/\1/p')
echo "   duration=$D"
if [ -n "$D" ]; then
  T=$(awk -v d="$D" 'BEGIN{printf "%.2f", d-5}')
  LC_ALL=C $IPC $SOCK cmd seek "$T" absolute >/dev/null 2>&1
  echo "   已 seek 到 $T，逐 2 秒采样："
  for n in $(seq 1 8); do
    S1=$(LC_ALL=C $IPC $SOCK status 2>/dev/null)
    P=$(LC_ALL=C $IPC $SOCK raw '{"command":["get_property","playlist-pos"],"request_id":1}' 2>/dev/null | tail -1 | sed -n 's/.*"data":\([0-9-]*\).*/\1/p')
    printf "     t+%2ds  status=%s  playlist-pos=%s\n" "$((n*2))" "$S1" "$P"
  done
fi

echo
echo "== 6. 手动换曲命令（后台遥控要用）=="
echo "   playlist-next -> $(LC_ALL=C $IPC $SOCK cmd playlist-next 2>&1 | head -1)"
sleep 2
echo "   之后 playlist-pos = $(LC_ALL=C $IPC $SOCK raw '{"command":["get_property","playlist-pos"],"request_id":1}' 2>/dev/null | tail -1 | sed -n 's/.*"data":\([0-9-]*\).*/\1/p')"
echo "   playlist-prev -> $(LC_ALL=C $IPC $SOCK cmd playlist-prev 2>&1 | head -1)"

echo
echo "== 7. 播放完整个列表后 mpv 会不会自己退出（决定唤醒锁怎么释放）=="
echo "   当前 mpv 进程: $(pgrep -f "[i]nput-ipc-server=$SOCK" | tr '\n' ' ')"
echo "   跳到最后一首结尾..."
LAST=$(( $(LC_ALL=C $IPC $SOCK raw '{"command":["get_property","playlist-count"],"request_id":1}' 2>/dev/null | tail -1 | sed -n 's/.*"data":\([0-9]*\).*/\1/p') - 1 ))
LC_ALL=C $IPC $SOCK cmd playlist-play-index "$LAST" >/dev/null 2>&1
sleep 2
D2=$(LC_ALL=C $IPC $SOCK raw '{"command":["get_property","duration"],"request_id":1}' 2>/dev/null | tail -1 | sed -n 's/.*"data":\([0-9.]*\).*/\1/p')
[ -n "$D2" ] && LC_ALL=C $IPC $SOCK cmd seek "$(awk -v d="$D2" 'BEGIN{printf "%.2f", d-4}')" absolute >/dev/null 2>&1
for n in $(seq 1 7); do
  sleep 2
  ALIVE=$(pgrep -f "[i]nput-ipc-server=$SOCK" | head -1)
  ST=$(LC_ALL=C $IPC $SOCK status 2>/dev/null)
  echo "     t+$((n*2))s  mpv_pid=${ALIVE:-已退出}  status=${ST:-无响应}"
  [ -z "$ALIVE" ] && break
done

echo
echo "== 清理 =="
pkill -f "[i]nput-ipc-server=$SOCK" 2>/dev/null; rm -f $SOCK; true
