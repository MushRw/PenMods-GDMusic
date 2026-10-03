#!/bin/bash
# 验证「加歌入口」—— 静态接线断言 + 把真源码抠出来求值的行为断言。
#
# 这一轮改动最容易坏的四种形态（都不是"少写一个函数"那种一眼能看出来的）：
#   ① 载体没做双形态补全 ⇒ 已下载的歌加不进离线歌单、没登记的本地歌进不了在线歌单
#   ② localRecOf 偷用 preferLocal ⇒ 用户一关"已下载优先"，离线歌单就再也加不进东西
#   ③ addPickEntries 与歌单对象同引用 ⇒ 加完一首后徽标还写着"加入"，再点就报 E_DUP
#   ④ 长按入口没 longFired 守卫 ⇒ 某些 Qt 行为下长按会顺手把歌播起来
# 所以主体是「求值真函数 + 接线断言」，静态查函数名一个都测不出上面这些。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && (pwd -W 2>/dev/null || pwd))"
QML="$ROOT/plugin/qml/main.qml"
AP="$ROOT/plugin/qml/pages/AddToPlaylistPage.qml"
PP="$ROOT/plugin/qml/pages/PlayerPage.qml"
LP="$ROOT/plugin/qml/pages/LocalPage.qml"
SP="$ROOT/plugin/qml/pages/SearchPage.qml"
DP="$ROOT/plugin/qml/pages/PlaylistDetailPage.qml"
IB="$ROOT/plugin/qml/components/IconButton.qml"
DIR="$ROOT/plugin/qml/qmldir"
NODE="${NODE:-}"
[ -x "$NODE" ] || NODE=$(command -v node)
for f in "$QML" "$AP" "$PP" "$LP" "$SP" "$DP" "$IB" "$DIR"; do
    [ -f "$f" ] || { echo "找不到 $f"; exit 1; }
done

"$NODE" - "$QML" "$AP" "$PP" "$LP" "$SP" "$DP" "$IB" "$DIR" <<'JS'
'use strict'
const fs = require('fs')
const [qmlPath, apPath, ppPath, lpPath, spPath, dpPath, ibPath, dirPath] = process.argv.slice(2)

const src = fs.readFileSync(qmlPath, 'utf8')
const ap  = fs.readFileSync(apPath,  'utf8')
const pp  = fs.readFileSync(ppPath,  'utf8')
const lp  = fs.readFileSync(lpPath,  'utf8')
const sp  = fs.readFileSync(spPath,  'utf8')
const dp  = fs.readFileSync(dpPath,  'utf8')
const ib  = fs.readFileSync(ibPath,  'utf8')
const dir = fs.readFileSync(dirPath, 'utf8')

const clean = s => s.replace(/^[ \t]*\/\/.*$/gm, '')
const qmlC = clean(src), apC = clean(ap), ppC = clean(pp),
      lpC = clean(lp), spC = clean(sp), dpC = clean(dp), ibC = clean(ib)

let pass = 0
const fails = []
function check(cond, msg) {
    if (cond) { pass++; return true }
    fails.push(msg); return false
}
function grab(text, name) {
    const i = text.indexOf('function ' + name + '(')
    if (i < 0) throw new Error('找不到 function ' + name)
    let depth = 0, k = text.indexOf('{', i)
    for (; k < text.length; k++) {
        const c = text[k]
        if (c === '{') depth++
        else if (c === '}') { depth--; if (depth === 0) break }
    }
    if (depth !== 0) throw new Error(name + ' 花括号未配平')
    return text.slice(i, k + 1)
}
function grabBinding(text, decl) {
    const i = text.indexOf(decl)
    if (i < 0) throw new Error('找不到 ' + decl)
    let depth = 0, k = text.indexOf('{', i)
    for (; k < text.length; k++) {
        const c = text[k]
        if (c === '{') depth++
        else if (c === '}') { depth--; if (depth === 0) break }
    }
    if (depth !== 0) throw new Error(decl + ' 花括号未配平')
    return 'function _bound() ' + text.slice(text.indexOf('{', i), k + 1)
}

const md = src.match(/readonly property string downloadDir:\s*"([^"]+)"/)
if (!md) { console.error('读不到 downloadDir'); process.exit(1) }
const D = md[1]

// ============================================================
// A. 文件与 qmldir
// ============================================================
check(/AddToPlaylistPage 1\.0 pages\/AddToPlaylistPage\.qml/.test(dir), 'A1 qmldir 未注册 AddToPlaylistPage')
check(/objectName:\s*"gdAddPickList"/.test(apC), 'A2 AddToPlaylistPage 缺列表 objectName')

// ============================================================
// B. main.qml 接线
// ============================================================
check(/Pages\.AddToPlaylistPage\s*\{/.test(qmlC), 'B1 main.qml 未实例化 Pages.AddToPlaylistPage')
check(/page\s*===\s*"addpick"/.test(qmlC), 'B2 加歌页没有 visible 绑定 page === "addpick"')

// 声明顺序：全实例化靠 visible 切换，z = 声明顺序。加歌页压在最后。
const iSearch = qmlC.indexOf('Pages.SearchPage')
const iMat    = qmlC.indexOf('Pages.MatchPage')
const iAdd    = qmlC.indexOf('Pages.AddToPlaylistPage')
check(iAdd > iSearch && iAdd > iMat, 'B3 加歌页必须声明在最后（否则被前面的页盖住）')

const open = grab(qmlC, 'openAddPick')
check(/addTargetOf\(song\)/.test(open),        'B4 openAddPick 没先归一化载体')
check(/addPickSong\s*=\s*t/.test(open),        'B5 openAddPick 没设 addPickSong')
check(/addPickStep\s*=\s*"list"/.test(open),   'B6 openAddPick 没把 step 复位成 list')
// ⚠️ 必须带 page !== "addpick" 的守卫：重复打开会把 backPage 写成 "addpick"，
//    之后「关闭」永远回到本页 ⇒「怎么按返回都出不去」，且只在特定顺序下出现。
check(/if \(page !== "addpick"\)\s*backPage\s*=\s*page/.test(open),
      'B7 openAddPick 无条件写 backPage ⇒ 重复打开后返回会永远回到加歌页')
check(/page\s*=\s*"addpick"/.test(open),       'B8 openAddPick 没切页')

const close = grab(qmlC, 'closeAddPick')
check(/addPickSong\s*=\s*null/.test(close),   'B9 closeAddPick 没清 addPickSong（下次进来残留上一首）')
check(/addPickStep\s*=\s*"list"/.test(close), 'B10 closeAddPick 没复位 step')
check(/page\s*=\s*backPage/.test(close),      'B11 closeAddPick 没回到来处')

const dop = grab(qmlC, 'doAddPick')
check(/addSongToPlaylist\(id,\s*addPickSong\)/.test(dop), 'B12 doAddPick 没把载体交给 addSongToPlaylist')
check(/!res\.ok/.test(dop) && /plErrText/.test(dop),      'B13 doAddPick 失败时没给具体原因（只靠"没反应"最难查）')
check(/closeAddPick\(\)/.test(dop),                        'B14 doAddPick 成功后没关页（会让人以为没加上）')

const bcf = grab(qmlC, 'beginCreateFromPick')
check(/addTargetFits\(addPickSong,\s*type\)/.test(bcf), 'B15 beginCreateFromPick 没先判这首歌能不能进该类型')
check(/beginCreatePlaylist\(type,\s*addPickSong\)/.test(bcf), 'B16 beginCreateFromPick 没把载体带进新建流程')

const bc = grab(qmlC, 'beginCreatePlaylist')
check(/plNewSong\s*=\s*\(song === undefined\)\s*\?\s*null\s*:\s*song/.test(bc),
      'B17 beginCreatePlaylist 的第二参没做 undefined→null（从歌单页新建时会存进字符串 "undefined"）')

// ============================================================
// C. 把 localRecOf / addTargetOf 抠出来求值
// ============================================================
const PRELUDE = [
    'var downloadDir = ' + JSON.stringify(D),
    'var preferLocal = true, minLocalBytes = 65536',
    'var localList = [], fileMap = ({})',
    'var playlists = [], plCurId = "", plNewType = "", plNewSong = null',
    'var addPickSong = null, addPickStep = "list"',
    'var playlistMax = 20, playlistSongMax = 300, playlistNameMax = 24',
    'var source = "netease"',
    'var page = "", backPage = "", editTarget = "", saveCalls = 0, warns = []',
    'var toast = { last: "", show: function (m) { this.last = String(m) } }',
    'var keyboard = { opened: null, calls: 0, open: function (t) { this.opened = t; this.calls++ } }',
    'var console = { warn: function (m) { warns.push(String(m)) }, log: function () {}, error: function () {} }',
    'var __v',
    'function savePlaylists() { saveCalls++ }',
    grab(qmlC, 'sanitizeName'),
    grab(qmlC, 'localNameFor'),
    grab(qmlC, 'localPathFor'),
    grab(qmlC, 'songKeyOf'),
    grab(qmlC, 'mappedPathFor'),
    grab(qmlC, 'mapEntryOf'),
    grab(qmlC, 'findLocal'),
    grab(qmlC, 'localRecOf'),
    grab(qmlC, 'copySong'),
    grab(qmlC, 'addTargetOf'),
    grab(qmlC, 'addTargetFits'),
    grab(qmlC, 'sanitizeSong'),
    grab(qmlC, 'plKeyOf'),
    grab(qmlC, 'playlistTypeText'),
    grab(qmlC, 'playlistIndexById'),
    grab(qmlC, 'playlistById'),
    grab(qmlC, 'playlistHasSong'),
    grab(qmlC, 'clonePlaylists'),
    grab(qmlC, 'addSongToPlaylist'),
    grab(qmlC, 'cleanPlaylistName'),
    grab(qmlC, 'createPlaylist'),
    grab(qmlC, 'beginCreatePlaylist'),
    grab(qmlC, 'openAddPick'),
    grab(qmlC, 'closeAddPick')
].join('\n')

function makeScope(bindingSrc) {
    const body = PRELUDE + '\n' + (bindingSrc || '') + '\n' + [
        'var __viewFn = function () { return _bound() }',
        'return {',
        '  gp:   function (n) { return eval(n) },',
        '  sp:   function (n, v) { __v = v; eval(n + " = __v") },',
        '  warns: warns,',
        '  saves: function () { return saveCalls }',
        '}'
    ].join('\n')
    return new Function(body)()
}
const vs = makeScope('')

const ONLINE = { id: '1', source: 'netease', name: '晴天', artist: '周杰伦' }
const HIT = D + '/晴天-周杰伦.mp3'

// ---- localRecOf：与 preferLocal 必须解耦 ----
vs.sp('localList', [{ file: HIT, size: 9000000, name: '晴天', artist: '周杰伦' },
                    { file: D + '/半截.mp3', size: 1024, name: '半截', artist: 'x' }])
vs.sp('fileMap', ({}))
check(vs.gp('localRecOf')(ONLINE) && vs.gp('localRecOf')(ONLINE).file === HIT,
      'C1 在线歌命中本地时 localRecOf 没返回那条记录')
check(vs.gp('localRecOf')({ id: '2', source: 'netease', name: '没有', artist: '无' }) === null,
      'C2 未命中时 localRecOf 应返回 null')
check(vs.gp('localRecOf')({ id: '3', source: 'netease', name: '半截', artist: 'x' }) === null,
      'C3 半截文件（< minLocalBytes）不该被当成可加入的本地歌 —— 离线歌单要保证"加进去就播得出来"')
check(vs.gp('localRecOf')({ file: '/x/y.mp3' }) === null,
      'C4 本地条目必须与 localList 求交（文件已被外部删掉却还显示"能加"是最糟的失败方式）')
check(vs.gp('localRecOf')(null) === null, 'C5 null 入参应返回 null 而不是抛')

// ❗核心：关掉"已下载优先"之后，localRecOf 仍要能找到文件。
//    若它偷用了 preferLocal，用户一关这个开关，所有歌就都加不进离线歌单了 ——
//    而症状（离线歌单永远是空的）完全看不出是这个开关干的。
vs.sp('preferLocal', false)
check(vs.gp('localRecOf')(ONLINE) && vs.gp('localRecOf')(ONLINE).file === HIT,
      'C6 关掉"已下载优先"后 localRecOf 就找不到文件了 —— 它不该受这个偏好影响')
vs.sp('preferLocal', true)

// ---- addTargetOf：双形态补全 ----
const t1 = vs.gp('addTargetOf')(ONLINE)
check(t1 && t1.id === '1' && t1.file === HIT,
      'C7 已下载的在线歌应同时带 id（在线歌单要）和 file（离线歌单要）')
check(t1 && t1.size === 9000000, 'C8 载体应把本地文件大小带上（离线歌单要显示体积）')
check(ONLINE.file === undefined, 'C9 addTargetOf 改到了入参本身（必须是浅拷贝）')

// 本地条目 + 登记表 ⇒ 补出网易云身份
const LOCFILE = D + '/改过名的文件.mp3'
vs.sp('localList', [{ file: LOCFILE, size: 5000000, name: '改过名的文件', artist: '' }])
vs.sp('fileMap', JSON.parse('{"' + LOCFILE + '": {"id":"77","source":"netease",'
           + '"name":"真名","artist":"真歌手","pic_id":"p1","lyric_id":"l1"}}'))
const t2 = vs.gp('addTargetOf')({ file: LOCFILE, name: '改过名的文件', artist: '', size: 5000000 })
check(t2 && t2.id === '77' && t2.source === 'netease',
      'C10 本地条目若在登记表里，载体应补出 id/source（否则它只能进离线歌单，白白少一个去处）')
check(t2 && t2.name === '真名' && t2.artist === '真歌手',
      'C11 载体应顺带用登记表的真名真歌手（歌单里显示"改过名的文件"毫无意义）')
check(t2 && t2.pic_id === 'p1' && t2.lyric_id === 'l1', 'C12 载体丢了 pic_id/lyric_id（封面与歌词会退化成空白）')

// 什么身份都没有
const t3 = vs.gp('addTargetOf')({ name: '无身份' })
check(t3 && !t3.file && !t3.id, 'C13 什么形态都没有时载体既无 file 也无 id（openAddPick 据此拒绝）')
check(vs.gp('addTargetOf')(null) === null, 'C14 addTargetOf(null) 应返回 null')

// ---- addTargetFits ----
vs.sp('localList', [{ file: HIT, size: 9000000, name: '晴天', artist: '周杰伦' }])
vs.sp('fileMap', ({}))
const both = vs.gp('addTargetOf')(ONLINE)
check(vs.gp('addTargetFits')(both, 'online') === true,  'C15 双形态载体应能进在线歌单')
check(vs.gp('addTargetFits')(both, 'local') === true,   'C16 双形态载体应能进离线歌单')
check(vs.gp('addTargetFits')({ name: '无' }, 'online') === false, 'C17 无 id 的载体进不了在线歌单')
check(vs.gp('addTargetFits')({ name: '无' }, 'local') === false,  'C18 无 file 的载体进不了离线歌单')

// ---- openAddPick / closeAddPick：backPage 绝不能被自己污染 ----
vs.sp('page', 'local'); vs.sp('backPage', '')
vs.gp('openAddPick')(ONLINE)
check(vs.gp('page') === 'addpick' && vs.gp('backPage') === 'local', 'C19 首次打开：切页且记下 backPage')
vs.gp('openAddPick')(ONLINE)          // 重复打开（探针的 7b 就是在钉这一条）
check(vs.gp('backPage') === 'local',
      'C20 ★ 重复打开把 backPage 写成了 "' + vs.gp('backPage') + '" ⇒ 之后「关闭」永远回到本页，出不去')
vs.gp('closeAddPick')()
check(vs.gp('page') === 'local', 'C21 关闭后回到来处（实际 ' + vs.gp('page') + '）')
check(vs.gp('addPickSong') === null, 'C22 关闭后载体清空')

// 没形态的歌要被拒（否则进到一个永远显示"没有歌"的空页）
vs.sp('page', 'local')
vs.gp('openAddPick')({ name: '无身份' })
check(vs.gp('page') === 'local' && vs.gp('toast').last === '这首歌没有可保存的信息',
      'C23 无形态的歌不该切页，且要说明原因')

// ============================================================
// D. addPickEntries：四种可加性 + 值重建
// ============================================================
const entriesSrc = grabBinding(qmlC, 'readonly property var addPickEntries:')
const statSrc    = grabBinding(qmlC, 'readonly property string addPickStat:')
const es = makeScope(entriesSrc)
const ts = makeScope(statSrc)

const mkPl = (id, type, songs) => ({ id, name: 'P' + id, type, created: 1, songs })
const onlineOnly = { id: '1', source: 'netease', name: '晴天', artist: '周杰伦' }

es.sp('addPickSong', { id: '1', source: 'netease', name: '晴天', artist: '周杰伦' })
es.sp('playlists', [])
check(es.gp('__viewFn')().length === 0, 'D1 没有歌单时 addPickEntries 应为空数组')
es.sp('addPickSong', null)
es.sp('playlists', [mkPl('a', 'online', [])])
check(es.gp('__viewFn')().length === 0, 'D2 没有载体时不该产出条目（否则页面会显示一列空行）')
es.sp('addPickSong', { id: '1', source: 'netease', name: '晴天', artist: '周杰伦' })

// ok
es.sp('playlists', [mkPl('a', 'online', [])])
check(es.gp('__viewFn')()[0].state === 'ok', 'D3 空在线歌单对在线歌应是 ok')
check(es.gp('__viewFn')()[0].typeText === '在线', 'D4 typeText 没跟着类型走')

// dup
es.sp('playlists', [mkPl('a', 'online', [{ id: '1', source: 'netease', name: '晴天', artist: '周杰伦' }])])
check(es.gp('__viewFn')()[0].state === 'dup', 'D5 已在歌单里的歌应判 dup（否则点了会报 E_DUP，用户以为坏了）')

// type：离线歌单收不了在线歌
es.sp('playlists', [mkPl('b', 'local', [])])
check(es.gp('__viewFn')()[0].state === 'type', 'D6 离线歌单对纯在线歌应判 type（而不是 ok）')

// 本地载体进离线歌单 ⇒ ok；进在线歌单 ⇒ type
es.sp('addPickSong', { file: HIT, name: '晴天', artist: '周杰伦', size: 9000000 })
es.sp('playlists', [mkPl('c', 'local', [])])
check(es.gp('__viewFn')()[0].state === 'ok', 'D7 本地歌进离线歌单应是 ok')
es.sp('playlists', [mkPl('c', 'online', [])])
check(es.gp('__viewFn')()[0].state === 'type', 'D8 纯本地歌进在线歌单应判 type')

// full
const full = mkPl('d', 'online', [])
for (let i = 0; i < 300; i++) full.songs.push({ id: 'x' + i, source: 'netease', name: 'n', artist: 'a' })
es.sp('addPickSong', { id: '1', source: 'netease', name: '晴天', artist: '周杰伦' })
es.sp('playlists', [full])
check(es.gp('__viewFn')()[0].state === 'full', 'D9 满的歌单应判 full（让用户提前看到，而不是点完才被拒）')

// ❗值重建：加完一首后，徽标必须从 ok 变 dup —— 靠的是条目对象**每次重建**。
es.sp('playlists', [mkPl('a', 'online', [])])
const e1 = es.gp('__viewFn')()
es.gp('addSongToPlaylist')('a', es.gp('addPickSong'))
const e2 = es.gp('__viewFn')()
check(e2 !== e1, 'D10 addPickEntries 两次返回同一引用 ⇒ 加完徽标不会变（这正是要防的坑）')
check(e2[0].state === 'dup', 'D11 加入之后 state 没有从 ok 变 dup')
check(e2[0].count === 1, 'D12 加入之后 count 没更新（副标题会一直写"空歌单"）')

// ---- addPickStat ----
ts.sp('addPickEntries', [])
ts.sp('playlists', [])
check(ts.gp('__viewFn')() === '还没有歌单', 'D13 没歌单时统计文案不对：' + ts.gp('__viewFn')())
ts.sp('addPickEntries', [{ state: 'ok' }, { state: 'dup' }, { state: 'type' }])
check(ts.gp('__viewFn')() === '3 个歌单 · 1 个可加入',
      'D14 统计只数可加入的那些：' + ts.gp('__viewFn')())

// ============================================================
// E. 新建歌单 → 自动把这首加进去
// ============================================================
const acc = grab(qmlC, 'onKeyboardAccepted')
check(/t === "plName"/.test(acc), 'E1 onKeyboardAccepted 没有 plName 分支')
const b = acc.indexOf('t === "plName"')
let depth = 0, k = acc.indexOf('{', b), end = k
for (; k < acc.length; k++) {
    if (acc[k] === '{') depth++
    else if (acc[k] === '}') { depth--; if (depth === 0) { end = k; break } }
}
const branch = acc.slice(b, end + 1)
check(/addSongToPlaylist\(res\.id,\s*plNewSong\)/.test(branch),
      'E2 从加歌页新建后没有把歌一并加进去（用户点"新建"就是为了放它）')
check(/var fromPick\s*=\s*!!plNewSong/.test(branch), 'E3 没区分"从加歌页新建"与"从歌单页新建"')
check(/if \(fromPick\) closeAddPick\(\)/.test(branch),
      'E4 建完没回到加歌页之前的地方（会停在加歌页，用户得自己按返回）')
check(/if \(!res\.ok\)[^}]*return/.test(branch), 'E5 歌单没建成时不该继续往下走')
// fromPick 的判断必须在 plNewSong 被清空**之前**。
// ⚠️ 用 lastIndexOf 而不是 indexOf：失败分支里也有一次 `plNewSong = null`（提前 return），
//    indexOf 会命中那一处、把正确的代码报成错的。
check(branch.indexOf('fromPick = !!plNewSong') < branch.lastIndexOf('plNewSong = null'),
      'E6 fromPick 取在 plNewSong 被清空之后 ⇒ 恒为 false，加歌页新建后不会自动加歌')

check(/onDismissed:\s*root\.plNewSong\s*=\s*null/.test(qmlC),
      'E7 键盘取消时没清 plNewSong（下次在歌单页新建会把这首一起塞进去）')

// ============================================================
// F. 四个入口
// ============================================================
check(/kind:\s*"plus"/.test(ppC), 'F1 播放页没有 plus 按钮')
check(/objectName:\s*"gdPlayerAddBtn"/.test(ppC), 'F2 播放页加歌按钮没有 objectName')
check(/openAddPick\(playerPage\.controller\.currentSong\)/.test(ppC),
      'F3 播放页加歌按钮没传 currentSong')
check(/k === "plus"/.test(ibC), 'F4 IconButton 不认识 plus（点了画不出图形）')
check(/plus\|/.test(ibC.replace(/[^|]/g, '')) || /play \| pause \| prev \| next \| download \| plus/.test(ibC),
      'F5 IconButton 的 kind 注释没更新 plus（后面加按钮的人会漏掉）')

// 三处长按
check(/onPressAndHold:/.test(lpC) && /openAddPick\(localPage\.controller\.localList\[index\]\)/.test(lpC),
      'F6 本地页行长按没接 openAddPick(localList[index])')
check(/onPressAndHold:/.test(spC) && /openAddPick\(searchPage\.controller\.results\[index\]\)/.test(spC),
      'F7 搜索页行长按没接 openAddPick(results[index])')
check(/onPressAndHold:/.test(dpC) && /openAddPick\(detailPage\.songs\[index\]\)/.test(dpC),
      'F8 详情页行长按没接 openAddPick(songs[index])')

// ❗longFired 守卫：Qt 长按后一般不再发 clicked，但"一般"不能当保证。
//    少了守卫，一旦某个 Qt 版本两者都发，用户长按一下就"打开加歌页 + 顺手播起来"。
for (const [name, t] of [['LocalPage', lpC], ['SearchPage', spC], ['PlaylistDetailPage', dpC]]) {
    check(/property bool longFired:\s*false/.test(t), 'F9 ' + name + ' 的整行点击区没有 longFired 守卫')
    check(/onPressedChanged:\s*if \(pressed\) longFired = false/.test(t),
          'F10 ' + name + ' 没在按下时重置 longFired（会一直卡在"上一次长按过"）')
    check(/onClicked:\s*\{\s*if \(longFired\)\s*\{\s*longFired = false;\s*return\s*\}/.test(t),
          'F11 ' + name + ' 的 onClicked 没在长按后早退（长按会顺手触发播放）')
}

// 长按是个没有视觉痕迹的手势 —— 不写出来用户永远不会发现
check(/objectName:\s*"gdLocalLongPressHint"/.test(lpC), 'F12 本地页底部没有长按提示')
check(/长按/.test(dpC), 'F13 详情页底部提示没提长按')

// ⚠️ 必须显式设 pressAndHoldInterval：默认值取自 QStyleHints，
//    平台返回 -1（"本平台不支持长按"）时定时器根本不启动 ⇒ 长按入口变成死代码，
//    而且不报任何错。这条一旦被"清理掉"就是静默功能回归。
for (const [name, t] of [['LocalPage', lpC], ['SearchPage', spC], ['PlaylistDetailPage', dpC]]) {
    const m = t.match(/pressAndHoldInterval:\s*(\d+)/)
    check(!!m, 'F14 ' + name + ' 没显式设 pressAndHoldInterval（平台可能返回 -1 ⇒ 长按静默失效）')
    if (m)
        check(Number(m[1]) >= 400 && Number(m[1]) <= 1500,
              'F15 ' + name + ' 的长按间隔 ' + m[1] + 'ms 不合适（<400 滚动易误触，>1500 等太久）')
}

// ============================================================
// G. 加歌页结构
// ============================================================
for (const n of ['gdAddPickSrcRow', 'gdAddPickShapeTag', 'gdAddPickList', 'gdAddPickRowTapArea',
                 'gdAddPickBadge', 'gdAddPickNewBtn', 'gdAddPickTypeCol',
                 'gdAddPickTypeOnline', 'gdAddPickTypeOffline', 'gdAddPickTypeBack'])
    check(apC.indexOf('"' + n + '"') > 0, 'G1 AddToPlaylistPage 缺 objectName ' + n)

check(apC.indexOf('gdAddPickRowTapArea') < apC.indexOf('gdAddPickBadge'),
      'G2 整行点击区必须声明在徽标之前（否则徽标点不动 —— 本地页/搜索页都栽过）')
check(/width:\s*320/.test(apC) && /height:\s*170/.test(apC), 'G3 加歌页尺寸不是 320×170')
check(/step === "type"[\s\S]{0,200}closeAddPick\(\)/.test(apC),
      'G4 返回键在 list 态没接 closeAddPick')
check(/step === "type"\s*$/m.test(apC) || /if \(pickPage\.step === "type"\)\s*pickPage\.controller\.addPickStep = "list"/.test(apC),
      'G5 返回键在 type 态没退回 list（会直接离开整页）')
check(/addPickStep = "type"/.test(apC), 'G6 「+ 新建歌单」没切到 type 态')
check(/beginCreateFromPick\(modelData\.t\)/.test(apC), 'G7 type 态没走 beginCreateFromPick')
check(/doAddPick\(entry\.id\)/.test(apC), 'G8 列表行没接 doAddPick')
check(/addTargetFits\(pickPage\.song,\s*modelData\.t\)/.test(apC), 'G9 type 态没按载体形态灰掉不可选类型')
check(!/controller\.playlists\s*\[/.test(apC), 'G10 页面直接索引 controller.playlists（必须走 addPickEntries）')
check(!/controller\.addPickSong\s*\[/.test(apC), 'G11 页面直接索引 addPickSong')

// 灰掉的行点下去必须说明为什么
check(/toastMsg\(stateHint\(\)\)/.test(apC), 'G12 不可加的行点了没给原因（用户只会以为界面卡了）')
check(/function stateHint\(\)/.test(apC), 'G13 缺 stateHint')

// U+25xx / U+2190 这批字形设备字体基本没有，会显示成豆腐块
const badGlyph = apC.match(/[\u25B6\u25B7\u25C0\u2190\u2605\u2606\u2714\u2716\uFF08\uFF09]/g)
check(!badGlyph, 'G14 加歌页里用了可能缺字形的符号：' + (badGlyph ? badGlyph.join(' ') : ''))

// 严格布尔：`a && b` 在缺项时返回 undefined 本身，赋给 bool 属性会每帧刷警告
const badBool = []
for (const line of apC.split('\n')) {
    const m = line.match(/^\s*(visible|enabled|clip|asynchronous|font\.bold)\s*:\s*(.+)$/)
    if (!m) continue
    const expr = m[2].trim()
    if (expr.includes('&&') && !expr.includes('!!') && !/\?/.test(expr)) badBool.push(line.trim())
}
check(badBool.length === 0, 'G15 加歌页里 bool 属性可能收到 undefined（缺 !! 收敛）：' + badBool.join(' | '))

// 页面调用的 controller 成员必须真的存在
const mainMembers = new Set()
for (const re of [/function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/g,
                  /property\s+(?:var|string|int|bool|double|color)\s+([A-Za-z_][A-Za-z0-9_]*)/g,
                  /readonly\s+property\s+(?:var|string|int|bool|double|color)\s+([A-Za-z_][A-Za-z0-9_]*)/g,
                  /signal\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/g])
    for (const m of qmlC.matchAll(re)) mainMembers.add(m[1])
const missing = []
for (const t of [apC, ppC, lpC, spC, dpC]) {
    for (const m of t.matchAll(/controller\.([A-Za-z_][A-Za-z0-9_]*)/g))
        if (!mainMembers.has(m[1])) (missing.indexOf(m[1]) < 0) && missing.push(m[1])
}
check(missing.length === 0, 'G16 页面调用了 main.qml 里不存在的 controller 成员 → ' + missing.join(','))

// ============================================================
// H. 括号配平
// ============================================================
// ⚠️ 必须**剥掉字符串、注释、正则字面量**再数：正则里散落着括号、
//    `"`、`/`（如 sanitizeName 的 `/[\/\\:\*\?"<>\|]/g`、ncMapSongs 的
//    `/(\d{10,})\.(?:jpg|png)$/i`）。旧版不认正则，正则里的 `"` 会把剥离器
//    带进"字符串模式"吞掉后续括号 ⇒ 正确代码报"差 2 个"。
//    识别正则的规则刻意保守：仅当前一非空白字符是 = ( , : ; ! & | ? { } [ 换行、
//    或前文是 return/case/typeof/instanceof/throw/void 时才按正则跳过；除法（a / b）
//    的前一字符是标识符/数字，不会被误判。
function countPairs(text, open, close) {
    let d = 0, inS = null, esc = false
    for (let i = 0; i < text.length; i++) {
        const c = text[i]
        if (inS) {
            if (esc) { esc = false; continue }
            if (c === '\\') { esc = true; continue }
            if (c === inS) inS = null
            continue
        }
        if (c === '"' || c === "'" || c === '`') { inS = c; continue }
        if (c === '/' && text[i + 1] === '/') { while (i < text.length && text[i] !== '\n') i++; continue }
        if (c === '/' && text[i + 1] === '*') {
            i += 2
            while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) i++
            i++
            continue
        }
        if (c === '/') {
            const prev = text.slice(Math.max(0, i - 12), i)
            const afterKw = /(return|case|typeof|instanceof|throw|void)\s*$/.test(prev)
            const pm = prev.match(/[^\s]$/)
            const afterPunct = pm && /[=(,:;!&|?{}[\n]/.test(pm[0])
            if (afterKw || afterPunct) {
                let j = i + 1, inCls = false, ok = true
                while (j < text.length) {
                    if (text[j] === '\\') { j += 2; continue }
                    if (text[j] === '[') inCls = true
                    else if (text[j] === ']') inCls = false
                    else if (text[j] === '/' && !inCls) break
                    else if (text[j] === '\n') { ok = false; break }   // 换行=不是正则
                    j++
                }
                if (ok) { i = j; continue }                             // 整个正则跳过
            }
        }
        if (c === open) d++
        else if (c === close) { d--; if (d < 0) return -1 }
    }
    if (inS) return -2
    return d
}
// 方括号：剥离器认正则字面量后 main.qml 也可以查（旧版被 sanitizeName 正则
// 里的 `"` 带偏，故只查新页面）。
for (const [name, t] of [['main.qml', src], ['AddToPlaylistPage.qml', ap],
                         ['PlayerPage.qml', pp], ['LocalPage.qml', lp],
                         ['SearchPage.qml', sp], ['PlaylistDetailPage.qml', dp],
                         ['IconButton.qml', ib]]) {
    for (const [o, c, label] of [['{', '}', '花括号'], ['(', ')', '圆括号']]) {
        const r = countPairs(t, o, c)
        check(r === 0, 'H1 ' + name + ' ' + label + '不配平（' +
              (r === -1 ? '提前闭合' : r === -2 ? '引号未闭合' : '差 ' + r + ' 个') + '）')
    }
}
for (const [name, t] of [['main.qml', src], ['AddToPlaylistPage.qml', ap], ['PlayerPage.qml', pp],
                         ['LocalPage.qml', lp], ['SearchPage.qml', sp],
                         ['PlaylistDetailPage.qml', dp], ['IconButton.qml', ib]]) {
    const r = countPairs(t, '[', ']')
    check(r === 0, 'H1 ' + name + ' 方括号不配平（差 ' + r + ' 个）')
}

console.log('')
if (fails.length) {
    console.log('FAIL ❌ ' + fails.length + ' 项未通过（pass=' + pass + '）')
    for (const f of fails) console.log('   - ' + f)
    process.exit(1)
}
console.log('PASS ✅ 加歌入口 · ' + pass + ' 项断言全过')
JS
