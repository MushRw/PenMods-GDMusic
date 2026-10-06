#!/bin/bash
# 验证「歌单数据层」—— 拿 main.qml 的真源码求值后断言。
#
# 沿用 preferlocal.sh / filemap.sh 的套路：**不喂假数据，而是把真源码抠出来求值**。
# 这类功能最容易坏的形态，假数据探针一种都测不出来：
#   ① 函数写了但没接上线（逻辑测试全绿、功能却没有）
#   ② 播歌单时直接把 playlists[i].songs 赋给 queue（没拷贝）⇒ 之后编辑歌单会
#      当场改掉正在播的队列，而且**不报任何错**
# 所以最后一组是**接线断言**（查函数体），中间有一组是**别名/引用断言**。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && (pwd -W 2>/dev/null || pwd))"
QML="$ROOT/plugin/qml/main.qml"
NODE="${NODE:-}"
[ -x "$NODE" ] || NODE=$(command -v node)
[ -f "$QML" ] || { echo "找不到 $QML"; exit 1; }

"$NODE" - "$QML" <<'JS'
'use strict'
const fs = require('fs')
const src = fs.readFileSync(process.argv[2], 'utf8')

// 去掉整行注释：注释里的花括号会把「括号配平」截取法带偏。
const clean = src.replace(/^[ \t]*\/\/.*$/gm, '')

function die(msg) { console.error('FAIL ❌ ' + msg); process.exit(1) }

function grab(name) {
    const i = clean.indexOf('function ' + name)
    if (i < 0) die('main.qml 里找不到 function ' + name)
    let depth = 0, k = clean.indexOf('{', i)
    if (k < 0) die(name + ' 找不到函数体')
    for (; k < clean.length; k++) {
        const c = clean[k]
        if (c === '{') depth++
        else if (c === '}') { depth--; if (depth === 0) break }
    }
    if (depth !== 0) die(name + ' 花括号未配平，截取失败')
    return clean.slice(i, k + 1)
}

// 三个上限从源码读，避免脚本与实现各说各话
function numProp(re, what) {
    const m = clean.match(re)
    if (!m) die('读不到 ' + what)
    return Number(m[1])
}
const PL_MAX   = numProp(/readonly property int playlistMax:\s*(\d+)/, 'playlistMax')
const SONG_MAX = numProp(/readonly property int playlistSongMax:\s*(\d+)/, 'playlistSongMax')
const NAME_MAX = numProp(/readonly property int playlistNameMax:\s*(\d+)/, 'playlistNameMax')

const md = src.match(/readonly property string downloadDir:\s*"([^"]+)"/)
if (!md) die('读不到 downloadDir')
const D = md[1]

// 歌单数据层 + resolveEntry 那条链（最后一组要验"歌单里的在线歌能命中本地"）
const body = ['songKeyOf', 'plKeyOf', 'copySong', 'clonePlaylists',
              'cleanPlaylistName', 'sanitizeSong',
              'sanitizePlaylist', 'parsePlaylists', 'playlistIndexById', 'playlistById',
              'playlistTypeText', 'playlistHasSong', 'plErrText',
              'createPlaylist', 'renamePlaylist', 'deletePlaylist',
              'addSongToPlaylist', 'removeSongFromPlaylist', 'removeSongAt', 'playPlaylist',
              'gotoPlayer',
              'sanitizeName', 'localNameFor', 'localPathFor', 'mappedPathFor',
              'findLocal', 'resolveEntry']
    .map(grab).join('\n\n')

// 用与 main.qml 同名的自由变量承载属性，函数闭包才能读到。
// startAt / savePlaylists 是 main.qml 的功能函数，在无头环境里换成可观测的桩 ——
// 这样"playPlaylist 到底把队列设成了什么、跳到了第几首、有没有落盘"全都能断言。
const api = new Function(`
var downloadDir = ${JSON.stringify(D)};
var preferLocal = true;
var minLocalBytes = 65536;
var localList = [];
var fileMap = ({});
var source = "netease";
var playlists = [];
var playlistMax = ${PL_MAX};
var playlistSongMax = ${SONG_MAX};
var playlistNameMax = ${NAME_MAX};
var queue = [];
var page = "";
var playerBackPage = "";
var idxHit = -1, saveCalls = 0, warns = [];
var console = { warn: function (m) { warns.push(String(m)) },
                log:  function () {} };
function startAt(i) { idxHit = i }
function savePlaylists() { saveCalls++ }
${body}
return {
  plKeyOf, cleanPlaylistName, sanitizeSong, sanitizePlaylist, parsePlaylists,
  playlistIndexById, playlistById, playlistTypeText, playlistHasSong, plErrText,
  createPlaylist, renamePlaylist, deletePlaylist,
  addSongToPlaylist, removeSongFromPlaylist, removeSongAt, playPlaylist,
  resolveEntry, localNameFor, localPathFor,
  limits: { plMax: playlistMax, songMax: playlistSongMax, nameMax: playlistNameMax },
  setPlaylists: function (v) { playlists = v },
  getPlaylists: function () { return playlists },
  getQueue:     function () { return queue },
  getPage:      function () { return page },
  getIdx:       function () { return idxHit },
  getSaveCalls: function () { return saveCalls },
  getWarns:     function () { return warns },
  setList:      function (l) { localList = l }
};
`)()

let pass = 0, bad = 0
function ok(cond, label) {
    if (cond) { pass++; console.log('  ✅ ' + label) }
    else { bad++; console.log('  ❌ ' + label) }
}
function reset() { api.setPlaylists([]); api.setList([]) }

const ONLINE = { id: '1997293311', source: 'netease', name: '断气', artist: '回春丹',
                 pic_id: '109951173449168898', lyric_id: '1997293311' }
const ONLINE2 = { id: '3439426789', source: 'netease', name: '铁花飞', artist: '回春丹' }
const ONLOCAL = { file: D + '/断气-回春丹.mp3', size: 11735293, name: '断气', artist: '回春丹' }
const ONLOCAL2 = { file: D + '/铁花飞-回春丹.mp3', size: 9000000, name: '铁花飞', artist: '回春丹' }

// =====================================================================
console.log('--- ① 去重键：两类条目各有各的键，且互不撞车 ---')
ok(api.plKeyOf(ONLOCAL) === ONLOCAL.file, '本地条目 → 用文件绝对路径作键')
ok(api.plKeyOf(ONLINE) === 'netease:1997293311', '在线条目 → 用 source:id 作键')
ok(api.plKeyOf(null) === "" && api.plKeyOf({}) === "", '空/无 id 无 file → 空键（不可入单）')

console.log('--- ② 类型约束：online 只收在线曲，local 只收本地曲 ---')
reset()
const rOnline = api.createPlaylist('我的歌', 'online')
ok(rOnline.ok && rOnline.id.indexOf('pl_') === 0, '新建在线歌单 → 返回 pl_ 开头的 id')
const rLocal = api.createPlaylist('离线必听', 'local')
ok(rLocal.ok, '新建离线歌单 ok')
ok(api.addSongToPlaylist(rOnline.id, ONLINE).ok, '在线歌单 ← 在线曲 → ok')
ok(api.addSongToPlaylist(rOnline.id, ONLOCAL).err === 'E_TYPE', '在线歌单 ← 本地曲 → E_TYPE')
ok(api.addSongToPlaylist(rLocal.id, ONLOCAL).ok, '离线歌单 ← 本地曲 → ok')
ok(api.addSongToPlaylist(rLocal.id, ONLINE).err === 'E_TYPE', '离线歌单 ← 在线曲 → E_TYPE')

console.log('--- ③ 形状归一化：入单后的条目形状由 type 决定 ---')
const plO = api.playlistById(rOnline.id), plL = api.playlistById(rLocal.id)
ok(plO.songs[0].id === '1997293311' && plO.songs[0].source === 'netease',
   '在线条目：id/source 保留')
ok(plO.songs[0].pic_id === '109951173449168898' && plO.songs[0].lyric_id === '1997293311',
   '在线条目：pic_id/lyric_id 保留（封面、歌词不断链）')
ok(plO.songs[0].file === undefined, '在线条目：绝不带 file 字段')
ok(plL.songs[0].file === ONLOCAL.file && plL.songs[0].size === 11735293,
   '本地条目：file/size 保留（与 parseLocalScan 输出同形）')
ok(plL.songs[0].id === undefined, '本地条目：不臆造 id')
ok(api.addSongToPlaylist(rOnline.id, { id: '5', source: 'netease' }).ok,
   '缺 name/artist 的在线条目也能进（只有 id 是硬要求）')
ok(api.addSongToPlaylist(rOnline.id, { name: 'x' }).err === 'E_TYPE',
   '完全没有 id 的在线条目 → E_TYPE（拒绝，不放坏数据进队列）')

console.log('--- ④ 去重：同类重复拒绝，换 id 放行 ---')
reset()
const rD = api.createPlaylist('D', 'online')
api.addSongToPlaylist(rD.id, ONLINE)
ok(api.addSongToPlaylist(rD.id, ONLINE).err === 'E_DUP', '同一首再加一次 → E_DUP')
ok(api.addSongToPlaylist(rD.id, { id: '1997293311', source: 'netease', name: '改过名' }).err === 'E_DUP',
   'id 相同、只有歌名不同 → 仍判重复（键是 source:id，不是歌名）')
ok(api.addSongToPlaylist(rD.id, { id: '1997293311', source: 'kuwo' }).ok,
   '换音源（kuwo:1997293311）→ 是另一首，放行')
ok(api.playlistById(rD.id).songs.length === 2, '此时歌单里 2 首')

console.log('--- ⑤ 上限：数量 / 曲目数 / 名字长度 ---')
reset()
ok(api.createPlaylist('   ', 'online').err === 'E_NAME', '纯空白名字 → E_NAME')
ok(api.createPlaylist('x', 'bogus').err === 'E_ARG', '未知类型 → E_ARG')
ok(api.cleanPlaylistName('  a\n\n b\tc  ') === 'a b c', '换行/制表/连续空白被压成一个空格')
ok(api.cleanPlaylistName('x'.repeat(NAME_MAX + 8)).length === NAME_MAX,
   '超长名字截断到 ' + NAME_MAX + ' 字')
for (let i = 0; i < PL_MAX; i++) api.createPlaylist('P' + i, 'online')
ok(api.getPlaylists().length === PL_MAX, '建满 ' + PL_MAX + " 个")
ok(api.createPlaylist('overflow', 'online').err === 'E_MAX', '第 ' + (PL_MAX + 1) + ' 个 → E_MAX')
const ids = api.getPlaylists().map(p => p.id)
ok(new Set(ids).size === ids.length, '全部 id 互不相同（同毫秒连续新建也要唯一）')
reset()
const rF = api.createPlaylist('F', 'online')
for (let i = 0; i < SONG_MAX; i++) api.addSongToPlaylist(rF.id, { id: String(i), source: 'netease' })
ok(api.playlistById(rF.id).songs.length === SONG_MAX, '塞满 ' + SONG_MAX + ' 首')
ok(api.addSongToPlaylist(rF.id, { id: 'x', source: 'netease' }).err === 'E_FULL',
   '再来一首 → E_FULL')

console.log('--- ⑥ 增删改：定位靠 id，删掉不影响别家 ---')
reset()
const a = api.createPlaylist('A', 'online'), b = api.createPlaylist('B', 'local')
api.addSongToPlaylist(a.id, ONLINE); api.addSongToPlaylist(a.id, ONLINE2)
api.addSongToPlaylist(b.id, ONLOCAL)
ok(api.renamePlaylist(a.id, '  改名了 ').ok && api.playlistById(a.id).name === '改名了',
   '改名（含首尾空白）→ 存下来的是去过空白的')
ok(api.renamePlaylist(a.id, '  ').err === 'E_NAME', '改成空名 → E_NAME，且原名字不变')
ok(api.playlistById(a.id).name === '改名了', '失败的重命名没有破坏原名字')
ok(api.removeSongFromPlaylist(a.id, 'netease:1997293311').ok
   && api.playlistById(a.id).songs.length === 1, '按 key 移除一首')
ok(api.removeSongFromPlaylist(a.id, 'netease:999').err === 'E_ARG', '移除不在单里的 key → E_ARG')
ok(api.removeSongAt(a.id, 0).ok && api.playlistById(a.id).songs.length === 0, '按行号移除')
ok(api.removeSongAt(a.id, 5).err === 'E_ARG', '行号越界 → E_ARG')
ok(api.deletePlaylist(a.id).ok, '删歌单 ok')
ok(api.playlistById(a.id) === null, '删掉后按 id 查不到')
ok(api.playlistById(b.id) !== null && api.getPlaylists().length === 1,
   '另一个歌单还在，且仍是 1 个（删除没误伤）')
ok(api.renamePlaylist('pl_nope', 'x').err === 'E_ARG', '改不存在的歌单 → E_ARG')
ok(api.deletePlaylist('pl_nope').err === 'E_ARG', '删不存在的歌单 → E_ARG')
ok(api.addSongToPlaylist('pl_nope', ONLINE).err === 'E_ARG', '往不存在的歌单加歌 → E_ARG')

console.log('--- ⑦ 播放：队列必须是【拷贝】，页面要翻到 player ---')
reset()
const p = api.createPlaylist('P', 'online')
api.addSongToPlaylist(p.id, ONLINE); api.addSongToPlaylist(p.id, ONLINE2)
const rp = api.playPlaylist(p.id, 1)
ok(rp.ok, '播歌单第 2 首 → ok')
ok(api.getPage() === 'player', '页面翻到 player')
ok(api.getIdx() === 1, 'startAt 收到的就是那首的序号')
ok(api.getQueue().length === 2, '整单进了队列（不是只放一首）')
ok(rp.ok && api.playlistById(p.id).songs.length === 2, '（歌单本身没被播放改动）')
// ⭐ 拷贝语义：这是"没拷贝"唯一能被抓住的地方
const before = api.getQueue()[1].name
api.addSongToPlaylist(p.id, { id: '999', source: 'netease', name: '后来加的' })
api.renamePlaylist(p.id, '改过名的歌单')
ok(api.getQueue().length === 2, '播放中添加歌 → 队列长度不变（不是同一个数组）')
ok(api.getQueue()[1].name === before, '播放中改名 → 队列里的条目不受影响')
ok(api.getQueue()[0] !== api.playlistById(p.id).songs[0], '队列条目是拷贝出来的新对象')
ok(api.getQueue()[0].id === api.playlistById(p.id).songs[0].id, '（拷贝内容仍然一致）')
ok(api.playPlaylist(p.id, 99).ok && api.getIdx() === api.playlistById(p.id).songs.length - 1,
   '越界序号被夹到最后一首，不报错')
const empty = api.createPlaylist('空', 'online')
ok(api.playPlaylist(empty.id, 0).err === 'E_EMPTY', '空歌单 → E_EMPTY（明确提示，不静默无反应）')
ok(api.playPlaylist('pl_nope', 0).err === 'E_EMPTY', '不存在的歌单 → E_EMPTY')

console.log('--- ⑧ 落盘：每次成功操作都要写库 ---')
const s0 = api.getSaveCalls()
const q = api.createPlaylist('Q', 'online')
api.addSongToPlaylist(q.id, ONLINE)
api.removeSongFromPlaylist(q.id, 'netease:1997293311')
api.renamePlaylist(q.id, 'Q2')
api.deletePlaylist(q.id)
ok(api.getSaveCalls() === s0 + 5, 'create/add/remove/rename/delete 各写一次库')
const s1 = api.getSaveCalls()
api.addSongToPlaylist(q.id, ONLINE)     // 已经删掉，必然失败
api.renamePlaylist(q.id, '')
api.createPlaylist('中文ok', 'bogus')
ok(api.getSaveCalls() === s1, '失败的操作**不写库**（别用无效状态覆盖好数据）')

console.log('--- ⑨ 容错：坏数据只丢自己，永不抛 ---')
ok(api.parsePlaylists('').length === 0, '空串 → []')
ok(api.parsePlaylists('not json at all').length === 0, '非 JSON → []')
ok(api.parsePlaylists('{"a":1}').length === 0, 'JSON 但不是数组 → []')
ok(api.parsePlaylists('[null, 5, "x", [], {}]').length === 0, '数组里的垃圾元素被逐条丢掉')
ok(api.parsePlaylists('[{"id":"p1","type":"online"},{"id":"","type":"online"},{"id":"p2","type":"???"}]').length === 1,
   '无 id / 未知 type 的歌单被丢，合法的留下')
const parsed = api.parsePlaylists(JSON.stringify(
    [{ id: 'p1', name: '', type: 'online', songs: [ONLINE, ONLINE, { name: 'no id' }] }]))
ok(parsed.length === 1 && parsed[0].name === '未命名歌单', '缺名字 → 「未命名歌单」')
ok(parsed[0].songs.length === 1, '单内重复与坏条目一并清掉（3 条 → 1 条）')
const big = api.parsePlaylists(JSON.stringify(
    new Array(PL_MAX + 5).fill(0).map((_, i) => ({ id: 'p' + i, type: 'online' }))))
ok(big.length === PL_MAX, '库里超量时只载入前 ' + PL_MAX + ' 个')
ok(api.getWarns().some(w => w.indexOf('超过上限') >= 0), '而且**告警**（不静默截断）')
const manySongs = api.parsePlaylists(JSON.stringify([{ id: 'p', type: 'online',
    songs: new Array(SONG_MAX + 3).fill(0).map((_, i) => ({ id: String(i), source: 'netease' })) }]))
ok(manySongs[0].songs.length === SONG_MAX, '单内超量时只保留前 ' + SONG_MAX + ' 首')

console.log('--- ⑩ 与 preferLocal 的衔接：在线歌单里已下载的歌，播的是本地 ---')
reset()
const mix = api.createPlaylist('混合', 'online')
api.addSongToPlaylist(mix.id, ONLINE)      // 已下载
api.addSongToPlaylist(mix.id, ONLINE2)     // 没下载
api.setList([ONLOCAL])                     // 磁盘上只有第一首
api.playPlaylist(mix.id, 0)
const q0 = api.getQueue()[0]
ok(q0.file === undefined, '队列里的原始条目仍然没有 file（歌单不存本地路径）')
ok(api.resolveEntry(q0).file === ONLOCAL.file, '第 1 首：resolveEntry 命中本地 ⇒ 播文件')
ok(api.resolveEntry(api.getQueue()[1]).file === undefined, '第 2 首：没下载 ⇒ 走网络，行为不变')
ok(api.localNameFor(ONLINE) === '断气-回春丹.mp3', '（命中靠的还是下载时那个命名公式）')

console.log('--- ⑪ 写操作的形态：每次都赋一个【完整的新数组】 ---')
// 真机实测结论（见 playlists-device.qml 的对照实验）：QML 赋 var 属性时会重算绑定，
// **即便赋的是同一个数组引用**。所以这里断言的不是"不换数组就不刷新"（那是错的），
// 而是「每次写都产出完整的新数组」这个不变量 —— 它让调用方不必关心自己
// 是不是在原地改，也不依赖那个未文档化的行为。
// 而且这条断言仍能防住真正的坑：**改了但忘了重新赋值**（那样绑定一定不重算）。
reset()
const arr0 = api.getPlaylists()
const rn = api.createPlaylist('N', 'online')
ok(api.getPlaylists() !== arr0, 'create → 换了新数组')
const arr1 = api.getPlaylists(); api.renamePlaylist(rn.id, 'N2')
ok(api.getPlaylists() !== arr1, 'rename → 换了新数组')
const arr2 = api.getPlaylists(); api.addSongToPlaylist(rn.id, ONLINE)
ok(api.getPlaylists() !== arr2, 'add → 换了新数组')
const arr3 = api.getPlaylists(); api.removeSongFromPlaylist(rn.id, 'netease:1997293311')
ok(api.getPlaylists() !== arr3, 'remove → 换了新数组')
const arr4 = api.getPlaylists(); api.deletePlaylist(rn.id)
ok(api.getPlaylists() !== arr4, 'delete → 换了新数组')

console.log('--- ⑫ 接线断言：函数体里必须真的调用到 ---')
;['createPlaylist', 'renamePlaylist', 'addSongToPlaylist', 'removeSongFromPlaylist']
    .forEach(function (n) {
        ok(/clonePlaylists\s*\(/.test(grab(n)), n + ' 里走 clonePlaylists()（每次都赋完整新数组）')
    })
const srcPlay = grab('playPlaylist')
ok(/copySong\s*\(/.test(srcPlay), 'playPlaylist 里调了 copySong()（防"直接赋引用"回归）')
ok(/startAt\s*\(/.test(srcPlay), 'playPlaylist 里调了 startAt()（否则只换页面不出声）')
const srcQjs = grab('queueJsonString')
ok(/resolveEntry\s*\(/.test(srcQjs),
   'queueJsonString 里仍走 resolveEntry() ⇒ 歌单条目与搜索页共用同一条"优先本地"通路')
const srcLoad = clean.slice(clean.indexOf('function loadSettings'), clean.indexOf('function saveSettings'))
ok(/parsePlaylists\s*\(/.test(srcLoad), 'loadSettings 里读歌单（parsePlaylists）')
ok(/playlists\s*=/.test(srcLoad), 'loadSettings 把结果赋给 playlists 属性')
const srcSave = grab('savePlaylists')
ok(/"playlists"/.test(srcSave), 'savePlaylists 写的 kv 键就是 "playlists"')
ok(/JSON\.stringify\s*\(\s*playlists\s*\)/.test(srcSave), 'savePlaylists 序列化的是 playlists 属性')
ok(/function\s+savePlaylists/.test(clean), 'savePlaylists 存在')
const srcReset = clean.slice(clean.indexOf('function resetAll'), clean.indexOf('function cycleSource'))
ok(!/playlists\s*=/.test(srcReset), 'resetAll 刻意不动歌单（设置 ≠ 用户内容资产）')

// ============ 歌单来源标记（网易云导入）============
// ⚠️ 重点是**存取往返**：sanitizePlaylist 是重建对象而不是浅拷贝，没显式透传的
//    字段会在 load 时被静默剥掉 ⇒ 标记"重启插件后没了"，而其它一切正常。
console.log('=== 歌单来源标记 source=netease ===')
{
  const s1 = api.sanitizePlaylist({ id: 'pl_1', name: 'A', type: 'online', source: 'netease', songs: [] })
  ok(s1 && s1.source === 'netease', 'sanitizePlaylist 保留 source=netease')
  const s2 = api.sanitizePlaylist({ id: 'pl_2', name: 'B', type: 'online', songs: [] })
  ok(s2 && s2.source === '', '没有 source 的歌单归一为空串（不是 undefined）')
  const s3 = api.sanitizePlaylist({ id: 'pl_3', name: 'C', type: 'online', source: 'xxx', songs: [] })
  ok(s3 && s3.source === '', '未知来源被丢弃（白名单，不把脏值带进库）')
  const round = api.parsePlaylists(JSON.stringify(
    [{ id: 'pl_1', name: 'A', type: 'online', source: 'netease', songs: [{ id: '1' }] }]))
  ok(round.length === 1 && round[0].source === 'netease',
     '存→读往返后标记还在（漏透传 = 静默丢失）')
}
ok(/source:\s*"netease"/.test(grab('ncMergeSynced')), '同步入库时给歌单打 source=netease')
// 存量回填：早先同步进来的歌单没有 source，不补就是"只有新拉的才有标记"
ok(/function ncMarkSyncedSource/.test(src), '提供存量歌单的来源回填 ncMarkSyncedSource')
ok(/ncMarkSyncedSource\(own\)/.test(grab('ncSyncPlaylists')),
   '同步拉到歌单列表后先回填标记（早于逐个拉取，拉取失败也已标上）')
ok(/pl\.source === "netease"\) continue/.test(grab('ncMarkSyncedSource')),
   '回填跳过已标记的（不重复写）')
ok(/if \(changed > 0\)/.test(grab('ncMarkSyncedSource')),
   '没有变化时不动数据（避免无意义的整体重赋值与落盘）')
// ⚠️ addPickEntries 是 property 绑定不是 function，grab() 找不到会直接 die
ok(/source: pl\.source \|\| ""/.test(src), '加入歌单页的条目快照带上 source')

console.log('')
if (bad) { console.error(`FAIL ❌ ${bad} 项未通过（共 ${pass + bad}）`); process.exit(1) }
console.log(`PASS ✅ 全部 ${pass} 项通过`)
JS
