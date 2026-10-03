#!/bin/sh
# 决定性问题：队列播完后 mpv 会不会自己退出？
#   -> 会退出：唤醒锁变孤儿会被 AudioDaemon 自动回收，无需额外处理（理想）
#   -> 不退出：需要额外机制释放锁，否则音频设备一直不关（耗电）
API="https://music-api.gdstudio.xyz/api.php"
IPS="104.18.0.1 104.17.0.1 104.19.0.1 104.20.0.1 104.16.0.1"
IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl
SOCK=/tmp/pl2.sock

api() {
  for ip in $IPS; do
    r=$(LC_ALL=C curl -s --max-time 6 -A 'Mozilla/5.0' \
        --resolve music-api.gdstudio.xyz:443:$ip "$API?$1" 2>/dev/null)
    case "$r" in "["*|"{"*) printf '%s' "$r"; return 0;; esac
  done
  printf '%s' "$r"
}
U=$(api "types=url&source=netease&id=5257138&br=320" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
case "$U" in http*) ;; *) echo "取流失败"; exit 1;; esac

run() {  # $1 = 组名, $2... = 额外参数
  NAME="$1"; shift
  echo "=========== $NAME ==========="
  pkill -f "[i]nput-ipc-server=$SOCK" 2>/dev/null; rm -f $SOCK; sleep 1
  nohup /userdisk/mpv/mpv --no-video --force-window=no --keep-open=no --volume=80 \
        --input-ipc-server=$SOCK "$@" "$U" >/tmp/pl2.log 2>&1 &
  i=0; while [ $i -lt 40 ]; do [ -S $SOCK ] && break; i=$((i+1)); sleep 0.25; done
  # 等真正开始播（属性可用）再 seek，避免「新文件未加载完 seek 被丢弃」
  n=0
  while [ $n -lt 20 ]; do
    D=$(LC_ALL=C $IPC $SOCK raw '{"command":["get_property","duration"],"request_id":1}' 2>/dev/null | sed -n 's/.*"data":\([0-9.]*\).*/\1/p')
    P=$(LC_ALL=C $IPC $SOCK raw '{"command":["get_property","time-pos"],"request_id":1}' 2>/dev/null | sed -n 's/.*"data":\([0-9.]*\).*/\1/p')
    [ -n "$D" ] && [ -n "$P" ] && break
    n=$((n+1)); sleep 1
  done
  echo "   duration=$D (等 ${n}s)"
  T=$(awk -v d="$D" 'BEGIN{printf "%.2f", d-3}')
  echo "   seek -> $T"
  LC_ALL=C $IPC $SOCK cmd seek "$T" absolute >/dev/null 2>&1
  for k in $(seq 1 8); do
    sleep 2
    A=$(pgrep -f "[i]nput-ipc-server=$SOCK" | head -1)
    if [ -z "$A" ]; then echo "   t+$((k*2))s  >>> mpv 已自行退出 <<<"; break; fi
    echo "   t+$((k*2))s  mpv_pid=$A  status=$(LC_ALL=C $IPC $SOCK status 2>/dev/null)"
  done
  pkill -f "[i]nput-ipc-server=$SOCK" 2>/dev/null; rm -f $SOCK; true
}

run "A 现状用法：--idle=yes"            --idle=yes
run "B 改成不带 idle（默认）"            --idle=no
