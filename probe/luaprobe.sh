#!/bin/sh
# 真机验证 mpv lua 的能力边界
IPC=/userdisk/PenMods/plugins/gdmusic/bin/gdipc.pl
SOCK=/tmp/lua.sock
DIR=/tmp/gdmusic

mkdir -p $DIR
rm -f $DIR/lua.log $DIR/probe_reply.txt
# 准备一份和真实队列同构的输入
cat > $DIR/in.json <<'EOF'
{"list":[{"id":"5257138","name":"测试歌A","artist":"歌手A"},
         {"id":"509781655","name":"测试歌B","artist":"歌手B"}],
 "index":0,"source":"netease","quality":"320",
 "ips":["104.18.0.1","104.17.0.1"],"autoNext":true,"apiBase":""}
EOF

# 取一个真实 url 让 mpv 有东西播（能触发 file-loaded）
U=$(for ip in 104.18.0.1 104.17.0.1 104.19.0.1; do
      r=$(LC_ALL=C curl -s --max-time 6 -A 'Mozilla/5.0' --resolve music-api.gdstudio.xyz:443:$ip \
          "https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=509781655&br=320" 2>/dev/null)
      echo "$r" | grep -q '"url"' && { echo "$r" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p'; break; }
    done)
echo "播放用 url: $(echo "$U" | cut -c1-60)..."
[ -z "$U" ] && { echo "取流失败，改为 idle 模式测脚本加载"; }

pkill -f "[i]nput-ipc-server=$SOCK" 2>/dev/null; rm -f $SOCK; sleep 1
if [ -n "$U" ]; then
  nohup /userdisk/mpv/mpv --no-video --force-window=no --keep-open=no --idle=yes \
        --input-ipc-server=$SOCK --script=/tmp/luaprobe.lua "$U" >/tmp/luaprobe_mpv.log 2>&1 &
else
  nohup /userdisk/mpv/mpv --no-video --force-window=no --keep-open=no --idle=yes \
        --input-ipc-server=$SOCK --script=/tmp/luaprobe.lua >/tmp/luaprobe_mpv.log 2>&1 &
fi

i=0; while [ $i -lt 40 ]; do [ -S $SOCK ] && break; i=$((i+1)); sleep 0.25; done
echo "socket 就绪 (等 ${i} 次)"

# 等探针跑一会儿（含 curl 异步返回）
sleep 10

echo
echo "=== 发 script-message 测遥控通路 ==="
LC_ALL=C $IPC $SOCK cmd script-message gd-probe hello 2>&1 | head -1
sleep 1

echo
echo "================ lua.log ================"
cat $DIR/lua.log 2>&1
echo "========================================="
echo "probe_reply: $(cat $DIR/probe_reply.txt 2>/dev/null || echo '(无)')"

echo
echo "=== mpv 自身日志里的 lua 错误（若有）==="
grep -iE 'lua|script|error' /tmp/luaprobe_mpv.log 2>/dev/null | head -15
echo "(以上为空则说明脚本零报错)"

echo
echo "=== 清理 ==="
pkill -f "[i]nput-ipc-server=$SOCK" 2>/dev/null; rm -f $SOCK; true
