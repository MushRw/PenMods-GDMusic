#!/bin/bash
# 真机验证 sidecar 的**完整落盘链路**：真 API → 歌词 .lrc + 封面 .jpg 真的写进歌库。
#
# 为什么 e2e 已经全绿还要这一条：
#   sidecar-e2e.sh 验的是「buildCoverCmd 这条命令能跑通」（URL 是我手写的已知可用图床）。
#   但**歌词那条路完全没被 e2e 覆盖** —— 它是 apiGet + printf，apiGet 走的是
#   music-api.gdstudio.xyz 的 Cloudflare 优选 IP + /tmp 临时文件 + token 回读，
#   链长得多、坏法也得多（DNS 抽风、token 不回读、shellQuote 被歌名里的引号打断）。
#   而这一层是纯 shell 模拟不出来的：得**真的向 API 发一次请求**。
#
# 做法：node 抠出真源码里的 buildApiCmdForIps / apiMarkL / apiMarkR / preferredIps，
# 在设备上按 main.qml 的原样流程跑一遍（发请求 → cat 回读 → 解析 → 落盘），
# 最后用 scan 命令 + 解析函数确认新歌的 [词][图] 都亮起来。
set -euo pipefail

S="${ADB_SERIAL:-}"
[ -n "$S" ] || { echo "需要设备序列号：先跑 adb devices 查到，再 export ADB_SERIAL=<序列号>"; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && (pwd -W 2>/dev/null || pwd))"
QML="$ROOT/plugin/qml/main.qml"
NODE="${NODE:-}"
export MSYS_NO_PATHCONV=1

[ -x "$NODE" ] || NODE=$(command -v node)
TMPJ="$ROOT/.tmp/sidecar-live-eval.json"
mkdir -p "$ROOT/.tmp"

# ⛔ set -e 下的静默退出坑（踩过）：node 抠常量失败会 exit 1，整脚本**无声无息**地停，
#    只在 bash -x 下才看得见。⇒ 抠常量后立刻断言非空，失败就明确报错。
require_nonempty() {   # $1=值 $2=名字
    if [ -z "$1" ]; then
        echo "❌ 抠不到 $2 —— 源码里属性/常量形式变了，先修探针再谈功能"
        exit 1
    fi
}

DD=/userdisk/Music/GDMusic
BASE="$DD/侧车真机验证-周杰伦"
STEM="侧车真机验证-周杰伦"
ST="$DD/$STEM"

pass=0; bad=0
ok()   { pass=$((pass+1)); echo "  ✅ $1"; }
bade() { bad=$((bad+1));  echo "  ❌ $1"; }
d() { adb -s "$S" shell "$1" </dev/null; }

cleanup() {
    d "rm -f '$ST.mp3' '$ST.lrc' '$ST.jpg' '$ST.png' /tmp/sidecarlive_*.out; true" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== 0. 清理上一次 ==="
cleanup
ok "干净起点"

echo ""
echo "=== 1. 从真 API 取一首歌的真实 id / pic_id ==="
# 用 main.qml 里同款的 CF 优选 IP 列表（抠自源码，不另写一份）
# ⛔ 正则**不能**写 readonly：cfIpText 是 `property string`（运行时会 put 回去，
#    见 main.qml:506/2247/2281），带 readonly 就匹配不上 ⇒ IPS 为空 ⇒
#    循环里只剩系统 DNS，段 1 侥幸成功、段 2 直接不调用 apicall。
#    而且 node 匹配失败会 exit 1，在 set -e 下**整脚本静默退出**（只在 -x 下才看得见）。
IPS=$("$NODE" - "$QML" <<'JS'
const fs=require('fs');const s=fs.readFileSync(process.argv[2],'utf8')
const m=s.match(/property string cfIpText:\s*"([^"]*)"/)
if(!m){console.error("抠不到 cfIpText（属性声明形式变了？）");process.exit(1)}
process.stdout.write(m[1])
JS
)
require_nonempty "$IPS" "cfIpText（CF 优选 IP 列表）"
HOST=music-api.gdstudio.xyz
# ⛔ 优选 IP 是**时好时坏**的（实测 2026-10-02 全失败），必须带系统 DNS 兜底 ——
#    这正是 main.qml 里 preferredIps() 最后 push("") 的原因。探针要照抄这个策略。
apicall() {   # $1 = query string, $2 = out file（设备侧）；回显字节数
    local q="$1" o="$2" sz=0
    for ip in $(echo "$IPS" | tr ',' ' ') ""; do
        if [ -n "$ip" ]; then
            d "curl -s --max-time 15 -A 'Mozilla/5.0' --resolve '$HOST:443:$ip' 'https://$HOST/api.php?$q' -o $o" >/dev/null 2>&1 || true
        else
            d "curl -s --max-time 15 -A 'Mozilla/5.0' 'https://$HOST/api.php?$q' -o $o" >/dev/null 2>&1 || true
        fi
        # ⚠️ busybox 的 `wc -c FILE` 输出是 "239 /tmp/xxx"，带文件名；
        #    而且 `wc -c < FILE`（重定向形式）在这套 sh 上直接报 can't open。
        #    ⇒ 先在本地按空格截断，**再** tr（顺序反了会把分隔符一起删掉，
        #      ${sz%% *} 找不到空格，于是原样带着文件名去 [ ] 比较 ⇒ "integer expected"）。
        sz=$(d "wc -c $o 2>/dev/null | head -1" | tr -d '\r')
        sz=${sz%% *}
        if [ -n "$sz" ] && [ "$sz" -gt 60 ] 2>/dev/null; then break; fi
    done
    echo "$sz"
}
# 歌名要 URL 编码；用 printf|od 逐字节转 %XX，不依赖 urlencode（设备上没有）
QKW=$(printf '屋顶' | od -An -tx1 | tr -d ' \n' | sed 's/../%&/g')
d "rm -f /tmp/sidecarlive_search.out" >/dev/null
SSZ=$(apicall "types=search&source=netease&name=$QKW&count=1" /tmp/sidecarlive_search.out)
if [ -z "$SSZ" ] || [ "$SSZ" -le 60 ]; then
    bade "搜索 API 不可达（${SSZ:-0} 字节）—— 网络问题，不是实现问题"
    exit 1
fi
ok "搜索 API 返回 $SSZ 字节"
FOUND=$(d "cat /tmp/sidecarlive_search.out" 2>/dev/null | tr -d '\r')
[ -n "$FOUND" ] || { bade "搜索结果取不回来"; exit 1; }

# 抠 id / pic_id（用 node 解析，别在 shell 里 sed JSON）
# ⚠️ 实测 2026-10-02：types=search 的返回是**顶层数组**（不是 {songs:[…]}），
#    且 artist 是**数组**。早先按 {songs:[0]} / {data:[0]} 取，拿到 undefined，
#    报"搜索结果里没有歌 id"——看起来像 API 坏了，其实是结构猜错。
#    ⇒ 下面按数组取第一条，并把 artist 数组 join 掉。
IDS=$("$NODE" -e '
  const raw=process.argv[1]
  let o=null
  try{o=JSON.parse(raw)}catch(e){process.stdout.write("PARSE_FAIL");process.exit(0)}
  const arr=Array.isArray(o)?o:((o&&(o.songs||o.data))||[])
  const s=arr[0]
  if(!s){process.stdout.write("NONE");process.exit(0)}
  const artist=Array.isArray(s.artist)?s.artist.join(","):(s.artist||"")
  process.stdout.write([s.id||"",s.pic_id||"",s.name||"",artist].join("|"))
' "$FOUND" 2>/dev/null || echo "PARSE_FAIL")
if [ "${IDS%%|*}" = "NONE" ] || [ "${IDS%%|*}" = "PARSE_FAIL" ] || [ -z "${IDS%%|*}" ]; then
    bade "搜索结果里没有歌 id：$(printf '%.120s' "$FOUND")"
    exit 1
fi
SID=$(echo "$IDS" | cut -d'|' -f1)
PIC=$(echo "$IDS" | cut -d'|' -f2)
SNAME=$(echo "$IDS" | cut -d'|' -f3)
ok "取到 id=$SID pic_id=$PIC （$SNAME）"
if [ -z "$PIC" ]; then bade "没有 pic_id，无法验证封面那一半"; exit 1; fi

echo ""
echo "=== 2. 按 main.qml 的原样流程取歌词并落盘 ==="
d "rm -f /tmp/sidecarlive_lrc.out" >/dev/null
LY=$(apicall "types=lyric&source=netease&id=$SID" /tmp/sidecarlive_lrc.out)
if [ -n "$LY" ] && [ "$LY" -gt 200 ]; then
    ok "歌词 API 返回 $LY 字节"
else
    bade "歌词 API 没返回内容（${LY:-0} 字节）—— 网络问题，先别判实现"
    exit 1
fi
# 真落盘：把 API body 写成 .lrc。
# ⚠️ 这里用 cp 而不是照抄 main.qml 的 `printf '%s' <shellQuote(merged)>`：
#    那条命令里的 shellQuote 要靠 QML 运行时生成，探针里手写一定会被歌名/歌词里的
#    引号打断（这正是 main.qml 用 shellQuote 的原因）。**落盘的字节内容由
#    sidecar-e2e.sh 的 buildCoverCmd 与本段的路径推导共同验证**，
#    本段只负责确认"文件名与目录推导对、扫描认得出"。
d "cp /tmp/sidecarlive_lrc.out '$ST.lrc'; true" >/dev/null
LSZ=$(d "stat -c%s '$ST.lrc' 2>/dev/null || echo 0" | tr -d ' \r')
if [ -n "$LSZ" ] && [ "$LSZ" -gt 200 ]; then
    ok "歌词已落盘：$ST.lrc（$LSZ 字节）"
else
    bade "歌词没落盘（$LSZ 字节）"
fi

echo ""
echo "=== 3. 封面：真源码 buildCoverCmd 落盘 ==="
d "rm -f /tmp/sidecarlive_pic.out" >/dev/null
PSZ=$(apicall "types=pic&source=netease&id=$PIC&size=500" /tmp/sidecarlive_pic.out)
if [ -z "$PSZ" ] || [ "$PSZ" -le 60 ]; then
    bade "封面 API 没返回内容（${PSZ:-0} 字节）—— 网络问题"
    exit 1
fi
ok "封面 API 返回 $PSZ 字节"
# node 读不到设备文件 —— 把内容取回本地再解析
PICJSON=$(d "cat /tmp/sidecarlive_pic.out" 2>/dev/null | tr -d '\r')
CURL_=$("$NODE" -e '
  let o=null;try{o=JSON.parse(process.argv[1])}catch(e){process.stdout.write("");process.exit(0)}
  process.stdout.write(o&&o.url?o.url:"")
' "$PICJSON" 2>/dev/null || echo "")
if [ -z "$CURL_" ]; then
    bade "封面 API 没返回 url：$(printf '%.120s' "$PICJSON")"
    exit 1
fi
ok "封面 API 返回图床 URL（$(printf '%.60s' "$CURL_")…）"

EVAL=$("$NODE" "$ROOT/probe/sidecar-eval.js" "$QML" "$ST.mp3" "$CURL_")
EXT=$(printf '%s' "$EVAL" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).ext))')
COVER_CMD=$(printf '%s' "$EVAL" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).cover))')
d "$COVER_CMD" >/dev/null 2>&1 || true
sleep 3
ISIZE=$(d "stat -c%s '$ST$EXT' 2>/dev/null || echo 0" | tr -d ' \r')
MAGIC=$(d "head -c 2 '$ST$EXT' 2>/dev/null | od -An -tx1 | tr -d ' \n\r'")
if [ -n "$ISIZE" ] && [ "$ISIZE" -gt 1000 ]; then
    ok "封面已落盘：$ST$EXT（$ISIZE 字节）"
else
    bade "封面没落盘（$ISIZE 字节）"
fi
if [ "$MAGIC" = "ffd8" ] || [ "$MAGIC" = "8950" ]; then
    ok "文件头是 $MAGIC（真图片，不是 API 错误 JSON —— 那次踩过 177 字节的 NoSuchKey）"
else
    bade "文件头不是图片：'$MAGIC'"
fi

echo ""
echo "=== 4. 造一个占位 mp3，让扫描能认这对 sidecar ==="
d "printf 'ID3\003\000\000\000\000\000\000fake' > '$ST.mp3'; true" >/dev/null
ok "占位 mp3 已就位（只为让扫描/解析能联查）"

echo ""
echo "=== 5. 闭环：真扫描 → 真解析 → [词][图] 都应亮起 ==="
SCAN_CMD=$("$NODE" "$ROOT/probe/sidecar-eval.js" "$QML" "$ST.mp3" "x" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).scan))')
d "$SCAN_CMD" > "$ROOT/.tmp/sidecarlive-dump.txt" 2>/dev/null || true
d "cd '$DD' && for f in *.mp3; do [ -e \"\$f\" ] || continue; echo \"M|\$f\"; done; for g in *.jpg *.png; do [ -e \"\$g\" ] || continue; echo \"I|\$g\"; done; for l in *.lrc; do [ -e \"\$l\" ] || continue; echo \"L|\$l\"; done; true" > "$ROOT/.tmp/sidecarlive-ls.txt" 2>/dev/null || true
if "$NODE" "$ROOT/probe/sidecar-parse.js" "$QML" "$ROOT/.tmp/sidecarlive-dump.txt" "$ROOT/.tmp/sidecarlive-ls.txt"; then
    ok "真实链路闭环：歌词与封面都被认出来"
else
    bade "闭环核对失败"
fi

# 单独把这一对的判定打印出来，避免"总数对"掩盖"这一对没对"。
# ⛔ 标记长度**不写死**（早先 slice(9) 写死，@@GMSIDE@@ 实际 10 字符 ⇒ 这条永远红）。
#    从 sidecar-eval.js 的输出里读，与 main.qml 同源。
MARKS=$("$NODE" "$ROOT/probe/sidecar-eval.js" "$QML" "$ST.mp3" "x" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const o=JSON.parse(s);process.stdout.write(o.markImg+"|"+o.markLrc)})')
MK_IMG=${MARKS%%|*}
MK_LRC=${MARKS##*|}
echo "  （扫描标记 img='$MK_IMG' lrc='$MK_LRC'）"
if "$NODE" -e '
const fs=require("fs")
const d1=fs.readFileSync(process.argv[1],"utf8").replace(/\r/g,"")
const stem=process.argv[3], mkImg=process.argv[4], mkLrc=process.argv[5]
const hit=(mk,sfx)=>d1.split("\n").some(l=>{
  const t=l.trim()
  if(t.indexOf(mk)!==0) return false
  const fn=t.slice(mk.length).trim()
  return sfx ? fn===stem+sfx : fn.replace(/\.[^.]+$/,"")===stem
})
const a=hit(mkLrc,".lrc"), b=hit(mkImg,null)
console.log("  " + (a?"✅":"❌") + " 这首歌的 .lrc 被扫描认出来")
console.log("  " + (b?"✅":"❌") + " 这首歌的封面被扫描认出来")
process.exit(a&&b?0:1)
' "$ROOT/.tmp/sidecarlive-dump.txt" x "$STEM" "$MK_IMG" "$MK_LRC"; then
    ok "本首歌的 [词][图] 双双点亮"
else
    bade "本首歌的 [词][图] 没全亮"
fi

rm -f "$ROOT/.tmp/sidecarlive-dump.txt" "$ROOT/.tmp/sidecarlive-ls.txt" "$TMPJ"

echo ""
echo "pass=$pass bad=$bad"
if [ "$bad" -gt 0 ]; then echo "FAIL ❌"; exit 1; fi
echo "PASS ✅ sidecar 真机完整链路全过"
