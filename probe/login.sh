#!/bin/bash
# 验证「网易云登录 + 歌单同步」—— 拿 main.qml 的真源码求值再断言。
#
# 覆盖四组：
#   A 纯函数：ncParseCheckCode（状态码解析）/ ncJarToCookie（jar→cookie 头）/
#             ncMapSongs（歌单详情→插件条目，含 pic_id 提取）/ ncFilterOwnPlaylists（过滤本人歌单）
#   B 命令生成：buildNcGetCmd / buildNcPostCmd / buildNcCheckCmd / buildNcQrCmd
#             （cookie 头、POST body、jar -c/-b、二维码 URL 编码）
#   C 接线断言：ncStartLogin 真的 POST unikey、ncPoll 真的轮询 check、
#               ncOnLoginSuccess 真的存 cookie、ncMergeSynced 真的写 playlists + savePlaylists
#   D 防御：空/坏 JSON 不崩、subscribed=true 被过滤、pic_id 正则边界
#
# ⚠️ 网络与设备真跑交给 probe/login-e2e.sh（命令在 /bin/sh 下真跑 + 真机扫码）。
#    本组只管"纯逻辑 + 接线"，穷举边界。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && (pwd -W 2>/dev/null || pwd))"
QML="$ROOT/plugin/qml/main.qml"
NODE="${NODE:-}"
[ -x "$NODE" ] || NODE=$(command -v node)
[ -f "$QML" ] || { echo "找不到 $QML"; exit 1; }

"$NODE" - "$QML" <<'JS'
'use strict'
const fs = require('fs')
const path = require('path')
const src = fs.readFileSync(process.argv[2], 'utf8')
const clean = src.replace(/^[ \t]*\/\/.*$/gm, '')
// 登录页也一并读进来：C 组的风控断言要检查界面有没有把限频显示出来。
// （放在最前面是因为 const 有 TDZ，后面再声明会在 C 组报 "before initialization"。）
const lpPath = path.join(path.dirname(process.argv[2]), 'pages', 'LoginPage.qml')
const lp = fs.readFileSync(lpPath, 'utf8')
function die(m) { console.error('FAIL ❌ ' + m); process.exit(1) }

function stripLiterals(s) {
    const out = s.split('')
    const mask = (a, b) => { for (let k = a; k < b && k < out.length; k++) out[k] = 'x' }
    let i = 0, n = s.length, prev = ''
    while (i < n) {
        const c = s[i]
        if (c === '"' || c === "'") {
            const q = c, st = i; i++
            while (i < n && s[i] !== q) { if (s[i] === '\\') i++; i++ }
            if (i >= n) return -2
            i++; mask(st, i); prev = 'x'; continue
        }
        if (c === '/' && s[i + 1] === '/') { const st = i; while (i < n && s[i] !== '\n') i++; mask(st, i); continue }
        if (c === '/' && s[i + 1] === '*') { const st = i; i += 2; while (i < n && !(s[i] === '*' && s[i + 1] === '/')) i++; i += 2; mask(st, i); prev = 'x'; continue }
        if (c === '/' && (prev === '' || '(,=:[!&|?{};+-*%~^'.indexOf(prev) >= 0)) {
            let j = i + 1, inCls = false, ok = false
            while (j < n && s[j] !== '\n') {
                if (s[j] === '\\') { j += 2; continue }
                if (s[j] === '[') inCls = true
                else if (s[j] === ']') inCls = false
                else if (s[j] === '/' && !inCls) { ok = true; break }
                j++
            }
            if (ok) { let k = j + 1; if (s[k] === 'g' || s[k] === 'i' || s[k] === 'm') k++; mask(i, k); i = k; prev = 'x'; continue }
        }
        if (!/\s/.test(c)) prev = c
        i++
    }
    return out
}

function grab(name) {
    const i = clean.indexOf('function ' + name)
    if (i < 0) die('main.qml 里找不到 function ' + name)
    let k = clean.indexOf('{', i)
    if (k < 0) die(name + ' 找不到函数体')
    const st = stripLiterals(clean.slice(i))
    if (st === -2) die(name + ' 引号未闭合')
    let depth = 0
    for (let j = k; j < clean.length; j++) {
        const c = st[j - i]
        if (c === '{') depth++
        else if (c === '}') { depth--; if (depth === 0) { k = j; break } }
    }
    if (depth !== 0) die(name + ' 花括号未配平')
    return clean.slice(i, k + 1)
}

function readStr(re, what) { const m = src.match(re); if (!m) die('读不到 ' + what); return m[1] }

let pass = 0, bad = 0
function ok(c, label) { if (c) { pass++; console.log('  ✅ ' + label) } else { bad++; console.log('  ❌ ' + label) } }
function eq(a, b, label) { ok(a === b, label + '  (得到 ' + JSON.stringify(a) + ')') }

// ============ A. 纯函数 ============
console.log('=== A. 登录状态机与数据映射（纯函数）===')
// ⚠️ 用数组 join 而非模板字符串 ${grab(...)}：本组函数里 ncMapSongs 含正则
//     /(\d{10,})\.(?:jpg|png)$/i，其 `$` 与 `${` 在模板字符串插值时会让
//     ncFilterOwnPlaylists / ncJarToCookie 的声明被吞掉（keys 少两个，且加一行
//     提前 grab 的 debug 就"碰巧"恢复 —— 典型的插值边界坑）。join 拼接彻底绕开。
const api = new Function([
  'var ncCookie = "";',
  'var ncUnikey = "";',
  "var shellQuote = function (s) { return \"'\" + String(s).replace(/'/g, \"'\\\\''\") + \"'\" };",
  grab('ncParseCheckCode'),
  grab('ncExtractCookie'),
  grab('ncMapSongs'),
  grab('ncFilterOwnPlaylists'),
  grab('ncJarToCookie'),
  'return {',
  '  parseCode: ncParseCheckCode, extractCookie: ncExtractCookie,',
  '  mapSongs: ncMapSongs, filterOwn: ncFilterOwnPlaylists, jarToCookie: ncJarToCookie',
  '};'
].join('\n'))()

// 状态码
eq(api.parseCode('{"code":800}'), 800, '800 过期')
eq(api.parseCode('{"code":801}'), 801, '801 待扫')
eq(api.parseCode('{"code":802}'), 802, '802 已扫待确认')
eq(api.parseCode('{"code":803}'), 803, '803 成功')
eq(api.parseCode('not json'), -1, '坏 JSON → -1')
eq(api.parseCode('{"foo":1}'), -1, '无 code → -1')

// jar → cookie 头
eq(api.jarToCookie('# Netscape HTTP Cookie File\n.netease.com\tTRUE\t/\tFALSE\t0\tMUSIC_U\tabc123\n'),
   'MUSIC_U=abc123', 'jar 单行解析')
eq(api.jarToCookie('# comment\n\n\t\t\n'),
   '', '空 jar / 纯注释 → 空串')
eq(api.jarToCookie('a\tb\tc\td\te'), '', '字段不足 7 列 → 跳过')

// 歌单详情 → 插件条目
const detail = { tracks: [
  { id: 1, name: '歌A', ar: [{ name: '甲' }, { name: '乙' }], al: { picUrl: 'https://p2.music.126.net/x/109951165671182684.jpg' } },
  { id: 2, name: '歌B', ar: [], al: null },
  { id: 0, name: '无id歌', ar: [{ name: '丙' }] },  // 无 id 应被跳过
  null,
] }
const mapped = api.mapSongs(detail)
eq(mapped.length, 2, '映射出 2 条（无 id / null 被跳过）')
eq(mapped[0].id, '1', 'id 转字符串')
eq(mapped[0].artist, '甲、乙', '多歌手用 、 连接')
eq(mapped[0].pic_id, '109951165671182684', '从 picUrl 提取 pic_id')
ok(mapped[1].pic_id === undefined, '无 picUrl 的歌不带 pic_id 字段')
ok(mapped[0].source === 'netease', 'source 恒 netease')

// 过滤本人歌单
const ownJson = JSON.stringify({ playlist: [
  { id: 11, name: '我的', trackCount: 5, subscribed: false },
  { id: 22, name: '收藏的', trackCount: 3, subscribed: true },
  { id: 33, name: '无subscribed字段', trackCount: 2 },
] })
const own = api.filterOwn(ownJson)
eq(own.length, 2, '只留本人建的（subscribed=true 被过滤）')
eq(own[0].id, '11', '第一条 id 正确')
eq(own[0].count, 5, 'trackCount 转 number')
eq(api.filterOwn('bad json').length, 0, '坏 JSON → 空数组')

// ============ B. 命令生成 ============
console.log('=== B. 命令生成（cookie / POST / jar / 二维码）===')
// 🔴 UA 与请求头必须"像浏览器"。2026-10-03 实测：扫码后服务端返回 8821
//   「请切换其他登录方式」= 环境风控；而我们三处命令都硬编码 `-A 'Mozilla/5.0'`
//   （残缺 UA）且不带 Accept/Accept-Language（curl 默认不发，真实浏览器必发）。
//   对照同设备 bili 插件（稳定登录）：完整 Chrome UA + Referer，登录走 C++ QtNetwork。
const NCUA = /readonly property string uaBrowser: "([^"]+)"/.exec(clean)[1]
ok(NCUA.length >= 60 && /Chrome\/\d+/.test(NCUA) && /AppleWebKit/.test(NCUA),
   'ncUa 是完整浏览器 UA（含 AppleWebKit + Chrome/版本），实测 len=' + NCUA.length)
ok(!/-A 'Mozilla\/5\.0'/.test(clean), '代码区不再出现残缺的 -A Mozilla/5.0（注释里为说明历史可留）')
// 全插件统一：GD / 图床 / 音乐下载都该用同一个 UA，别再各自硬编码
ok((clean.match(/-A " \+ shellQuote\(uaBrowser\)/g) || []).length >= 6,
   '全部 curl 命令（≥6 处）统一走 uaBrowser，实测 ' +
   (clean.match(/-A " \+ shellQuote\(uaBrowser\)/g) || []).length + ' 处')
ok(/Accept-Language:/.test(clean), '带 Accept-Language（curl 默认不发，浏览器必发）')

const cmdApi = new Function([
  'var ncCookie = "";',
  'var ncUnikey = "TESTKEY123";',
  'var uaBrowser = ' + JSON.stringify(NCUA) + ';',
  'var ncHdr = ' + JSON.stringify(/readonly property string ncHdr: "([^"]+)"/.exec(src)[1]) + ';',
  "var shellQuote = function (s) { return \"'\" + String(s).replace(/'/g, \"'\\\\''\") + \"'\" };",
  grab('ncCurlHdr'),
  grab('buildNcGetCmd'),
  grab('buildNcPostCmd'),
  grab('buildNcCheckCmd'),
  grab('ncQrContent'),
  grab('buildNcQrCmd'),
  grab('buildNcQrWaitCmd'),
  grab('buildNcSeedJarCmd'),
  'return {',
  '  get: buildNcGetCmd, post: buildNcPostCmd, check: buildNcCheckCmd,',
  '  qrContent: ncQrContent, qr: buildNcQrCmd, qrWait: buildNcQrWaitCmd,',
  '  seedJar: buildNcSeedJarCmd',
  '};'
].join('\n'))()

const getCmd = cmdApi.get('https://music.163.com/api/nuser/account/get', '/tmp/o', 'TKN')
ok(getCmd.indexOf("music.163.com/api/nuser/account/get") >= 0, 'GET 命令含目标 URL')
ok(getCmd.indexOf("-e 'https://music.163.com/'") >= 0, 'GET 带 Referer 压低风控')
ok(getCmd.indexOf(NCUA) >= 0, 'GET 用完整 UA（不是裸 Mozilla/5.0）')
ok(getCmd.indexOf('Accept-Language') >= 0, 'GET 带 Accept-Language 头')
ok(getCmd.indexOf('Cookie:') < 0, '无 cookie 时不带 Cookie 头')

// 有 cookie 时应带 -H Cookie
const cmdWithCk = new Function([
  'var ncCookie = "MUSIC_U=abc; __csrf=xyz";',
  'var uaBrowser = ' + JSON.stringify(NCUA) + ';',
  'var ncHdr = ' + JSON.stringify(/readonly property string ncHdr: "([^"]+)"/.exec(src)[1]) + ';',
  "var shellQuote = function (s) { return \"'\" + String(s).replace(/'/g, \"'\\\\''\") + \"'\" };",
  grab('ncCurlHdr'),
  grab('buildNcGetCmd'),
  'return buildNcGetCmd;'
].join('\n'))()
ok(cmdWithCk('https://music.163.com/x', '/tmp/o', 'T').indexOf("Cookie: MUSIC_U=abc") >= 0, '有 cookie 时带 -H Cookie')

const postCmd = cmdApi.post('https://music.163.com/api/login/qrcode/unikey', 'type=1', '/tmp/o', 'T')
ok(postCmd.indexOf('-X POST') >= 0, 'POST 带 -X POST')
ok(postCmd.indexOf('-d') >= 0 && postCmd.indexOf('type=1') >= 0, 'POST 带 -d type=1')
ok(postCmd.indexOf(NCUA) >= 0, 'POST（申请 unikey）同样用完整 UA')

const checkCmd = cmdApi.check('https://music.163.com/api/login/qrcode/client/login?key=K&type=1', '/tmp/jar', '/tmp/o', 'T')
ok(checkCmd.indexOf('-c') >= 0 && checkCmd.indexOf('-b') >= 0, 'check 带 -c/-b 存读 jar')
ok(checkCmd.indexOf('/tmp/jar') >= 0, 'check 引用 jar 路径')
ok(checkCmd.indexOf(NCUA) >= 0, 'check（轮询）同样用完整 UA')
// 🔴 种 os=pc/appver：网易云第三方客户端的通行标识。写 jar 而非 -H，
//    否则 -b jar 与 -H Cookie 并存会让 curl 发出两行 Cookie 头。
const seedCmd = cmdApi.seedJar('/tmp/jar')
ok(seedCmd.indexOf('os') >= 0 && seedCmd.indexOf('appver') >= 0, 'seedJar 种入 os=pc 与 appver')
ok(seedCmd.indexOf('grep -q') >= 0, 'seedJar 只在缺失时追加（不覆盖已有 NMTID）')
ok(seedCmd.indexOf('>>') >= 0, 'seedJar 用 >> 追加而非覆盖')
ok(hasIn('ncStartLogin', 'buildNcSeedJarCmd'), 'ncStartLogin 先种 jar 再申请 unikey')

const qrContent = cmdApi.qrContent()
eq(qrContent, 'https://music.163.com/login?codekey=TESTKEY123', '二维码内容 = 登录页 + unikey')
// ⚠️ buildNcQrCmd 只吃 outImg（图床 URL 由函数内部用 ncUnikey 拼）。
//    早先这里误传整条图床 URL 当 outImg，断言却照样通过 —— 蒙对的，
//    顺带把错误签名固化了下来。已按真实签名调用。
const qrCmd = cmdApi.qr('/tmp/gdmusic_nc_qr.png')
ok(qrCmd.indexOf('pwmqr.com') >= 0, '二维码走第三方 QR 服务')
ok(qrCmd.indexOf('curl -sL') >= 0, '二维码下载用 -sL')
ok(qrCmd.indexOf('--http1.1') >= 0, '二维码下载强制 HTTP/1.1（设备 h2 拿 200+空 body，2026-10-02 实测）')

// 二维码下载的「完成信号」命令：必须判非空 + 写 token 到 done 文件，
// 否则页面会在图还没落盘时就换 source（读到旧码 ⇒ 手机扫出「已失效」）。
const qrWaitCmd = cmdApi.qrWait('/tmp/gdmusic_nc_qr.png', '/tmp/qr.done', 'TKN42')
ok(qrWaitCmd.indexOf('pwmqr.com') >= 0, 'qrWait 仍走图床下载')
ok(qrWaitCmd.indexOf('TKN42') >= 0, 'qrWait 把 token 写进 done 文件')
ok(qrWaitCmd.indexOf('/tmp/qr.done') >= 0, 'qrWait 引用 done 路径')
ok(qrWaitCmd.indexOf('wc -c') >= 0, 'qrWait 用 wc -c 判字节数')
ok(qrWaitCmd.indexOf('-gt 0') >= 0, 'qrWait 只在非空时才写完成信号（0 字节图不算就绪）')

// ============ C. 接线断言 ============
console.log('=== C. 接线断言（函数真的互相调用）===')
function hasIn(fnName, needle) { return grab(fnName).indexOf(needle) >= 0 }
ok(hasIn('ncStartLogin', 'ncPost('), 'ncStartLogin 调 ncPost 申请 unikey')
ok(hasIn('ncStartLogin', '/api/login/qrcode/unikey'), '申请的是 unikey 接口')
ok(hasIn('ncStartLogin', 'ncPollTimer.restart'), '登录发起后启动轮询')

// ⚠️ 2026-10-03 真机事故四（限频风控 8821，症状 = "扫码授权完没反应"）：
//    4 秒内连点刷新 ⇒ 4 个 unikey + 2 秒一次轮询 ⇒ 服务端开始返回
//    {"code":8821,"message":"请切换其他登录方式或升级新版本再试"}。
//    老实现把白名单外的 code 一律当作"等下一拍重试"，于是界面继续显示
//    "请用手机网易云 App 扫码"、轮询不停 ⇒ 风控永不解除 + 用户零感知。
//    判据：`/tmp/gdmusic_api_*.out` 里出现 801 之后连续 8821。
//    修法三条缺一不可：① 非白名单 code → ncRisk（停轮询+冷却）② 轮询 2s→3s
//    ③ 冷却期间禁止重新申请 unikey（否则连点只会让风控窗口更长）。
{
  const poll = grab('ncOnPoll')
  ok(/ncRisk\(code\)/.test(poll), '非白名单 code 走 ncRisk（不能"等下一拍重试"了事）')
  const iRisk = poll.indexOf('ncRisk(')
  const i803  = poll.indexOf('code === 803')
  ok(iRisk > i803, 'ncRisk 分支在 800/801/802/803 之后（白名单优先，不误判成功态）')
  ok(/ncFail\+\+/.test(poll), '解析失败(-1)单独计数（网络抖动不该当风控）')
  ok(hasIn('ncRisk', 'ncPollTimer.stop'), 'ncRisk **停轮询**（继续刷风控永不解除）')
  ok(hasIn('ncRisk', 'ncCooldown = ncCoolSec'), 'ncRisk 进冷却')
  ok(hasIn('ncRisk', 'ncCoolTimer.restart'), 'ncRisk 启动冷却倒计时')

  const start = grab('ncStartLogin')
  ok(/if\s*\(\s*ncCooldown\s*>\s*0\s*\)\s*return/.test(start),
     '冷却期间禁止重新申请 unikey（否则连点让风控窗口更长）')

  // 轮询降频：2s→3s（802 后加快到 1s 保留跟手）
  const tt = src.slice(src.indexOf('id: ncPollTimer'), src.indexOf('id: ncPollTimer') + 200)
  ok(/interval:\s*\(ncPhase\s*===\s*"scanned"\)\s*\?\s*1000\s*:\s*3000/.test(tt),
     '轮询 3s 一拍（2s 实测会触发 8821），802 待确认时加快到 1s')

  // 界面必须把风控说出来 —— 否则用户看到的就是"扫码没反应"
  ok(/case\s*"risk"/.test(lp), '登录页 phaseText 有 risk 分支（把限频显示出来）')
  ok(/ncCooldown/.test(lp) && /\+\s*"\s*秒后可重试"/.test(lp),
     '登录页显示冷却倒计时（用户知道要等多久）')
  ok(/正在获取/.test(lp),
     '二维码未就绪时框内显示"正在获取…"（出码要 2~3s，空白会让用户以为卡住而连点）')
}

// ⚠️ 时序断言（顺序错纯函数断言抓不到，必须按源码位置比对）。
// 2026-10-02 真机事故：ncQrStamp++ 写在 ncPost **之前**，此时新码还没下载，
// 登录页 Image 换 source 后读到上一次的旧 PNG，再无 source 变化 ⇒ 屏上永远是旧码，
// 用户扫码得到「二维码已失效」，而服务端那个 unikey 其实一直是 801（好的）。
// 症状与"码过期"几乎无法区分，只能靠"解码 PNG 里的 codekey 与 ncUnikey 比对"定位。
ok(hasIn('ncStartLogin', 'ncWaitImg('), 'ncStartLogin 等 ncWaitImg 确认落盘，而不是直接 startDetached')
{
  const body = grab('ncStartLogin')
  // ⚠️ 2026-10-02 真机事故三（并发覆盖）：ncStartLogin 5 秒内被调两次
  //    （onVisibleChanged 进页 + 刷新按钮），两次各申请一个 unikey 并**并发 curl 写
  //    同一个固定 PNG 路径** ⇒ 后落盘的是 A 的码，插件却轮询 B 的 key ⇒ 永远 801，
  //    界面照旧显示"等待扫码"，**零异常表现**（实测屏上码 45206508、轮询 key 71b6ab0a）。
  //    两条必修：① 重入守卫；② 文件名带 unikey 前缀，不同码互不覆盖。
  ok(/if\s*\(\s*ncStarting\s*\)\s*return/.test(body),
     'ncStartLogin 有重入守卫（并发调用会申请两个 unikey，2026-10-02 实测）')
  ok(/ncStarting\s*=\s*true/.test(body) && /ncStarting\s*=\s*false/.test(body),
     'ncStarting 在发起前置 true、回调里复位 false（不会永久卡住）')
  ok(/ncUnikey\.substring\(0,\s*8\)/.test(body),
     '二维码文件名带 unikey 前缀（不同码落不同文件，不会互相覆盖）')
  ok(body.indexOf('shell.startDetached') < 0, 'ncStartLogin 不再直接 startDetached（那会失去落盘时机）')
  const iGuard = body.indexOf('if (ncStarting) return')
  const iPost  = body.indexOf('ncPost(')
  ok(iGuard >= 0 && iPost > 0 && iGuard < iPost, '守卫在 ncPost **之前**（否则拦不住并发申请）')
  // 旧回调的竞态：ncWaitImg 是异步的，旧 unikey 的回调可能晚到，必须核对归属
  ok(/ncUnikey\.substring\(0,\s*8\)\s*!==/.test(body),
     'ncWaitImg 回调核对 unikey 归属（旧回调晚到时不能覆盖新码）')
}
ok(!/ncQrStamp\+\+/.test(grab('ncStartLogin')),
   '不再用 ncQrStamp++ 换 source（路径本身唯一，天然绕过缓存）')
ok(/ncQrFile\s*=\s*img/.test(grab('ncStartLogin')),
   '落盘确认后才写 ncQrFile，页面只读这一个来源（不各自拼路径）')
ok(hasIn('ncWaitImg', 'buildNcQrWaitCmd'), 'ncWaitImg 走带完成信号的下载命令')
ok(hasIn('ncWaitImg', 'apiPending'), 'ncWaitImg 挂进 apiPending 复用统一回读机制')
ok(hasIn('ncWaitImg', 'needsBody: false'), 'ncWaitImg 标 needsBody=false（.done 里只有 token、无正文）')
// ⚠️ 2026-10-02 真机事故二：apiPoll 一律用 `body.length > 1` 判成功，
//    而 .done 文件里**只有 token 没有正文** ⇒ ok=false ⇒ 登录页一打开就"登录失败，点下方重试"。
//    症状超有迷惑性（网络全通、二维码也正常），必须锁死这条分支。
// 2026-10-03：判定搬到 apiFinish（apiPoll 改成两阶段：grep -c 探完成 → 命中才 cat 全文）
ok(hasIn('apiFinish', 'needsBody === false'), 'apiFinish 对 needsBody=false 的项只看 token 出现，不按正文长度判')
ok(!/\(body\.length > 1\)/.test(grab('apiFinish').replace(/p\.needsBody === false\) \? \(idx >= 0\) : \(body\.length > 1\)/, '')),
   'apiFinish 不再无条件用 body.length 判成功')
ok(hasIn('ncPoll', '/api/login/qrcode/client/login'), 'ncPoll 轮询 check 接口')
ok(hasIn('ncOnLoginSuccess', 'ncSaveCookie'), '登录成功存 cookie')
ok(hasIn('ncOnLoginSuccess', 'ncFetchAccount'), '登录成功后拉 uid/昵称')
ok(hasIn('ncSyncPlaylists', '/api/user/playlist'), '同步拉用户歌单列表')
ok(hasIn('ncMergeSynced', 'savePlaylists'), '合并后落盘歌单')
ok(hasIn('ncLogout', 'ncSaveCookie'), '退出登录清 cookie 并落盘')

// ============ D. 防御 ============
console.log('=== D. 防御（空/坏输入不崩）===')
ok(api.parseCode('') === -1, '空字符串 → -1')
ok(api.mapSongs(null).length === 0, 'mapSongs(null) → 空')
ok(api.mapSongs({}).length === 0, 'mapSongs(无 tracks) → 空')
ok(api.filterOwn('{"playlist":null}').length === 0, 'playlist 为 null → 空')
ok(api.jarToCookie('') === '', '空 jar 文本 → 空 cookie')

// ============ E. 登录页布局（320×170 塞不下竖排，必须左右分置）============
console.log('=== E. LoginPage 布局（左右分置 + 不溢出）===')
// ⚠️ 别复用 process.argv[2]（那是 main.qml，本组要读的是另一个文件）。
//    路径从 main.qml 所在目录推出来，这样 `bash probe/login.sh` 在任意 cwd 下都对。
// 断言只看**代码**：剥掉注释，否则注释里为了说明历史事故而写下的旧路径
// （如"以前这里读 /gdmusic_nc_qr.png"）会被当成代码命中，断言反过来被注释绑死。
const lpCode = lp.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/^[ \t]*\/\/.*$/gm, ' ')
{
  // 🔴 二维码 source 必须**只**来自 controller.ncQrFile（由 main.qml 在确认新码落盘后写）。
  //    页面自己拼固定路径 + cache-bust 时间戳是错的：下载是异步的，换 source 时新码
  //    还没落盘 ⇒ 读到旧图且此后不再重载（2026-10-02 两次真机事故都栽在这）。
  ok(/controller\.ncQrFile/.test(lpCode), '二维码 source 读 controller.ncQrFile（唯一来源）')
  ok(!/gdmusic_nc_qr\.png/.test(lpCode), '页面代码不再硬编码二维码路径（那是并发覆盖的根源）')
  ok(!/\?\s*t=/.test(lpCode), '不再用 ?t= cache-bust（文件名已唯一，无需时间戳）')
  ok(/:\s*""\s*$/.test(lpCode.split('\n').filter(l => /source:/.test(l)).slice(-1)[0] || '\n')
     || /ncQrFile[\s\S]{0,120}?""/.test(lpCode),
     'ncQrFile 为空时 source 给空串（不显示上一次残留的图）')
  // 竖排会超屏：TitleBar 32 + 二维码 116 + 文字 + 按钮 28 + spacing ⇒ >170。
  // 断言未登录区用 Item 分置（二维码 x=8，右列 x = qrBox.width + 20）。
  ok(/id: qrCol\s*\n\s*[^:]*:\s*Item/.test(lp) || /Item\s*\{\s*\n\s*id: qrCol/.test(lp),
     '未登录区根容器是 Item（可自由分置），不是 Column')
  ok(/id: qrBox[\s\S]{0,200}?x:\s*8\b/.test(lp), '二维码固定在左侧 x=8')
  ok(/qrBox\.width \+ \d+/.test(lp), '右列 x 基于 qrBox.width 定位（左右分置）')
  // 关键回归点：Column 不会自动撑开，height 必须显式给足（几何检查抓过 need=52 h=49）
  ok(/id: acctCol[\s\S]{0,200}?height:\s*parent\.height - 33/.test(lp), '已登录 Column 显式给 height')
  // 右列：必须显式给 height（≥70，容得下三行文字 + 28px 按钮）。
  // 不依赖属性书写顺序 —— 取 qrBox 定位那行之后、spacing 之前的那段。
  const rightCol = (lp.match(/x:\s*qrBox\.width \+ \d+[\s\S]{0,300}?height:\s*(\d+)/) || [])[1]
  ok(!!rightCol && Number(rightCol) >= 70, '右侧 Column 显式给足 height（防 COLUMN_OVERFLOW），实得 ' + rightCol)
  // 文字溢出：昵称/uid 必须限宽 + elide
  const elideCount = (lp.match(/elide: Text\.ElideRight/g) || []).length
  ok(elideCount >= 2, '昵称与 uid 都设了 elide（防长文本顶出屏幕），实得 ' + elideCount)
  ok(/wrapMode: Text\.WordWrap/.test(lp), '状态文字开 WordWrap（长句换行而非撑宽）')
  ok(/maximumLineCount: 3/.test(lp), '状态文字限 3 行')
}

// ============ F. 同步：一次拿全 + 可取消 + 限频退避 ============
// 2026-10-03 真机事故：点「同步我的歌单」后界面几分钟不动、返回键也退不出去。
// 三条根因，每条都必须锁死：
//   ① 每 400ms 把整份响应 cat 回主线程（歌单详情 500KB）⇒ UI 卡死
//   ② detail 响应里本来就带完整 tracks，却只用 trackIds 再走 song/detail 每 4 首一批
//      ⇒ 一个 205 首的歌单要 52 次请求，十几个歌单上千次请求
//   ③ 406「操作频繁」被当成"没 trackIds"静默跳过，界面却停在"拉取「xxx」"不动
console.log('=== F. 同步性能与可取消（2026-10-03 卡死事故）===')
{
  const poll = grab('apiPoll')
  ok(/grep -c/.test(poll), 'apiPoll 用 grep -c 探完成（不再每拍 cat 整份响应）')
  ok(!/cat " \+ apiPending/.test(poll) && !/cat \+? ?apiPending/.test(poll),
     'apiPoll 不再直接 cat pending 文件（500KB 每 400ms 回灌主线程 = 界面点不动）')
  ok(/apiFinish\(/.test(poll), '命中后才走 apiFinish 取正文（两阶段）')
  ok(hasIn('apiFinish', 'indexOf(p.token)'), 'apiFinish 仍按 token 位置截断正文')

  const next = grab('ncSyncNext')
  ok(/ncMapSongs\(o\.playlist\)/.test(next), '同步优先用 detail 自带的完整 tracks（一次拿全）')
  const iTracks = next.indexOf('ncMapSongs(o.playlist)')
  // 「song/detail」这串在 ncSyncNext 里只出现在注释中（会被 grab 剥掉），真正的回退
  // 路径是调用 ncFetchSongBatch —— 用它做位置断言。
  const iFallback = next.indexOf('ncFetchSongBatch(')
  ok(iTracks > 0 && iFallback > 0 && iTracks < iFallback,
     'song/detail 分批只作回退（排在 tracks 之后，不是默认路径）')
  ok(/code === 406/.test(next), '406 限频被显式识别（旧实现把限频响应当成空歌单静默丢）')
  ok(/ncSyncRetry/.test(next), '406 后走退避重试，而不是原地猛打')
  ok(/ncSyncAbort/.test(next), '同步每一步检查取消标志（用户点了取消能真的停）')
  ok(/歌单 " \+ \(i \+ 1\)/.test(next) || /歌单 /.test(next), '进度带 i/n（用户看得到在动）')

  ok(/function ncCancelSync/.test(src), '提供取消同步入口 ncCancelSync')
  ok(hasIn('ncCancelSync', 'ncSyncAbort = true'), '取消置标志（后台 curl 杀不掉，下一拍收尾）')
  ok(hasIn('ncSyncDone', 'ncSyncing = false'), '收尾必清 ncSyncing（不留永久"同步中"的悬空状态）')
  ok(hasIn('ncSyncPlaylists', 'ncSyncAbort'), '同步入口也检查取消标志')

  // 界面出口：同步中按钮必须变成"取消同步"，不能只是 enabled:false 让用户干等
  const lpC = lp.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/^[ \t]*\/\/.*$/gm, ' ')
  ok(/ncCancelSync/.test(lpC), '登录页在同步中调用 ncCancelSync（用户有出口）')
  ok(/busy\(\) \? "取消同步"/.test(lpC), '同步中按钮文案变「取消同步」')
  ok(!/enabled: !busy\(\)/.test(lpC), '同步中按钮不再被禁用（禁用=没有出口）')
  // ⚠️ 按钮文案让给「取消同步」之后，进度必须另有位置显示 —— 2026-10-03 把它们
  //    一起改掉而没补位置，用户看到的就是"点了同步、界面毫无反应"（后台其实在跑）。
  //    登录后 phaseText() 先返回"已登录"，永远轮不到同步进度，所以进度只能独立成行。
  ok(/height:\s*14[\s\S]{0,300}?ncSyncMsg/.test(lpC), '同步进度有独立显示位（不依赖按钮文案）')
  // 2026-10-03 第二轮：补位置补了两处 ⇒ 屏上同时出现两行一样的进度。
  //    已登录区（acctCol 之后）只能有**一个** text 绑 ncSyncMsg。
  //    ⚠️ 数 `text:` 而不是数 ncSyncMsg 字样：同一个 Text 里"判断 + 取值"会出现两次。
  const acct = lpC.slice(lpC.indexOf('id: acctCol'))
  const hits = (acct.match(/text:[\s\S]{0,160}?ncSyncMsg/g) || []).length
  ok(hits === 1, '已登录区进度提示只有一个（两个会同时显示两行），实得 ' + hits)
  // 🔴 回归点：同步**只可能**发生在已登录状态，而 phaseText 那行文字在未登录区 ——
  //    已登录区（acctCol）自己没有一个 ncSyncMsg 的显示点的话，进度就是零反馈。
  //    2026-10-03：按钮文案改成"取消同步"后进度彻底消失，用户判定"又不显示了"。
  const acctSeg = lpC.slice(lpC.indexOf('id: acctCol'))
  ok(acctSeg.length > 0 && /ncSyncMsg/.test(acctSeg),
     '已登录区（acctCol）有同步进度显示点（否则已登录时进度永远看不见）')
  const pt = lpC.slice(lpC.indexOf('function phaseText'))
  const iBusy = pt.indexOf('if (busy())')
  const iLogged = pt.indexOf('if (loggedIn())')
  ok(iBusy > 0 && iLogged > 0 && iBusy < iLogged,
     'phaseText 先判 busy 再判 loggedIn（反了的话"已登录：xxx"会把进度整段吃掉）')

  // ------------------------------------------------------------------
  // G. 导航：设置页必须出得去（2026-10-03「卡死」事故的另一半）
  //    用户在设置页点返回**纹丝不动**：openLogin 把共用的 backPage 写成了
  //    "settings"，于是 goBack() 把 page 又赋成它自己。这个 bug 没有报错、
  //    返回箭头看得见也点得着，只是页面不动 —— 只能靠源码断言锁死。
  //    位置断言比存在性断言强：只查"有 settingsBackPage"挡不住有人再写回
  //    backPage（两条路并存时以哪条为准看不出来）。
  console.log('')
  console.log('=== G. 导航：设置页返回不复发 ===')
  const nav = grab('goBack')
  ok(/settingsBackPage/.test(grab('openSettings')), 'openSettings 记住来处 settingsBackPage')
  // ⚠️ 只查 openLogin 的**函数体**，别查全文：解释这个坑的注释里必然出现
  //    `backPage = "settings"` 这串，全文匹配会永远红（探针自己骗自己）。
  ok(!/backPage/.test(grab('openLogin')), 'openLogin 不再污染 backPage（污染源已拔除）')
  ok(/page === "login"/.test(nav) && /page = "settings"/.test(nav), '登录页返回 → 设置页')
  ok(/settingsBackPage/.test(nav), '设置页返回 → 进设置前的那个页（不是它自己）')
}

console.log('')
console.log('pass=' + pass + ' bad=' + bad)
if (bad > 0) process.exit(1)
JS
