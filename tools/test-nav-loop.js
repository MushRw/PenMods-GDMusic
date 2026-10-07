#!/usr/bin/env node
// 复现「播放页 ↔ 队列页 互相跳转、退不出去」的导航死循环。
//
// 手法：从 main.qml **真源码**抽出 gotoPlayer / goPlayerBack / goQueueBack / openQueue，
// 用真实控制流跑一遍用户描述的按键序列，断言最终页面。
// 不复制逻辑 —— 复制一份来测等于测了个赝品。
'use strict'
const fs = require('fs')
const path = require('path')

const SRC = process.env.GD_MAIN_SRC
  || path.join(__dirname, '..', 'plugin', 'qml', 'main.qml')
const src = fs.readFileSync(SRC, 'utf8')

function extractFn(name) {
  const re = new RegExp('^\\s*function ' + name + '\\s*\\(', 'm')
  const m = re.exec(src)
  if (!m) throw new Error('找不到 ' + name)
  const open = src.indexOf('{', m.index)
  let d = 0, i = open, st = 'code', prev = ''
  const rx = (c) => c === '' || '(,=:[!&|?{};+-*%<>~^'.indexOf(c) >= 0
  for (; i < src.length; i++) {
    const c = src[i], n = src[i + 1]
    if (st === 'code') {
      if (c === '\n') continue
      if (c === '/' && n === '/') { st = 'lc'; i++; continue }
      if (c === "'") { st = 'sq'; continue }
      if (c === '"') { st = 'dq'; continue }
      if (c === '/' && rx(prev)) {
        let j = i + 1, inC = false
        for (; j < src.length; j++) { const dd = src[j]
          if (dd === '\\') { j++; continue }
          if (dd === '\n') break
          if (dd === '[') inC = true; else if (dd === ']') inC = false
          else if (dd === '/' && !inC) break }
        i = j; prev = 'x'; continue
      }
      if (c === '{') d++; else if (c === '}') { d--; if (d === 0) break }
      if (!/\s/.test(c)) prev = c
      continue
    }
    if (st === 'lc') { if (c === '\n') st = 'code'; continue }
    if (c === '\\') { i++; continue }
    if ((st === 'sq' && c === "'") || (st === 'dq' && c === '"')) { st = 'code'; prev = c }
  }
  return src.slice(m.index, i + 1)
}

// 导航层重构后（2026-10-07），gotoPlayer/goPlayerBack 内部走 navEnter/navLeave，
// 所以夹具必须把这一层也一起 eval 进来，否则会 ReferenceError。
// ⚠️ 这也说明测试**必须跟着实现走**：实现抽了层，夹具不跟就会变成"测了个空"。
const fns = ['gotoPlayer', 'goPlayerBack', 'goQueueBack', 'openQueue',
             'openSettings', 'goBack', 'openLogin',
             'navGet', 'navSet', 'navOriginOk', 'navWouldCycle', 'navEnter', 'navLeave']
const bodies = fns.map(extractFn).join('\n')

// 造一个最小桥对象：只有导航需要的状态
function makeNav() {
  const o = {
    page: 'playlists',
    playerBackPage: '',
    settingsBackPage: '',
    backPage: 'search',
    // 集中式导航的两张表（与 main.qml 保持同源；改一处要一起改）
    navDownstream: { 'player': ['queue'], 'settings': ['login'] },
    navFallback: { 'player': 'search', 'settings': 'playlists', 'addpick': 'search' },
    _log: [],
  }
  const factory = new Function('nav', `
    with (nav) {
      ${bodies}
      return { gotoPlayer: gotoPlayer, goPlayerBack: goPlayerBack,
               goQueueBack: goQueueBack, openQueue: openQueue,
               openSettings: openSettings, goBack: goBack, openLogin: openLogin }
    }
  `)
  o.api = factory(o)
  return o
}

let pass = 0, bad = 0
const ok = (c, label) => { if (c) { pass++; console.log('  [OK] ' + label) } else { bad++; console.log('  [XX] ' + label) } }

console.log('=== 用户描述的操作序列 ===')
console.log('  ① 播放页 → 打开播放列表（队列页）')
console.log('  ② 按返回')
console.log('  ③ 再按返回')
console.log('  ④ 再按返回（期望退出到上一级/歌单页，实际卡住）')
console.log('')

const n = makeNav()
n.page = 'player'          // 用户当前在播放页
n.playerBackPage = 'playlists'  // 之前从歌单页进来的

console.log('  起始: page=' + n.page + ' playerBackPage=' + n.playerBackPage)

n.api.openQueue()
console.log('  ① 打开播放列表后: page=' + n.page)

n.api.goQueueBack()
console.log('  ② 按返回后:       page=' + n.page + ' playerBackPage=' + n.playerBackPage
            + '   ← ⚠️ playerBackPage 被污染成 queue')

n.api.goPlayerBack()
console.log('  ③ 再按返回后:     page=' + n.page + ' playerBackPage=' + n.playerBackPage)

n.api.goQueueBack()
console.log('  ④ 再按返回后:     page=' + n.page + ' playerBackPage=' + n.playerBackPage)

console.log('')
console.log('=== 断言：反复返回应最终离开 player/queue 这对页面 ===')
// 模拟连按 10 次返回：如果实现正确，应该稳定停在 playlists（不再在 player/queue 之间来回）
const m = makeNav()
m.page = 'player'
m.playerBackPage = 'playlists'
m.api.openQueue()
const trail = []
for (let i = 0; i < 10; i++) {
  if (m.page === 'queue') m.api.goQueueBack()
  else if (m.page === 'player') m.api.goPlayerBack()
  else break
  trail.push(m.page)
}
console.log('  连按返回的页面轨迹: ' + trail.join(' → '))
const escaped = m.page !== 'player' && m.page !== 'queue'
ok(escaped, '连按返回能离开 player/queue（最终 page=' + m.page + '）')
ok(trail.indexOf('playlists') >= 0 || escaped, '能回到 playlists')

console.log('')
console.log('=== 关键：playerBackPage 是否被污染成 queue ===')
const k = makeNav()
k.page = 'player'
k.playerBackPage = 'playlists'
k.api.openQueue()
k.api.goQueueBack()
ok(k.playerBackPage !== 'queue',
   'goQueueBack 后 playerBackPage 不应变成 "queue"（实测 = "' + k.playerBackPage + '"）')

// ============================================================
// 最坏输入：把「来处」槽位直接污染成 自己 / 下游，看能否自锁。
// 为什么单列这一组：这个文件历史上三次死循环事故的形状**完全相同** ——
//   来处变量落进「自己」或「自己的下游」。三次的修法都是"再补一个 if 排除它"。
//   现在改成 navDownstream + navOriginOk 的结构性保证，所以要把**最坏输入**钉住：
//   即便槽位被外部写成非法值，返回也**必须**能退出去（退化到 fallback，绝不原地不动）。
//   「按了返回但页面没动」是最难查的症状：箭头在、点得着、也不报错。
// ============================================================
console.log('')
console.log('=== 最坏输入：来处槽位被污染成 自己 / 下游 ===')
function freshNav() {
  const x = makeNav()
  // 补上 settings/addpick 两条路径需要的槽位与函数
  x.settingsBackPage = 'search'
  x.backPage = 'search'
  return x
}
// ① settings 槽位被写成自己（历史上真实发生过）
{
  const x = freshNav()
  x.page = 'settings'; x.settingsBackPage = 'settings'
  x.api.goBack()
  ok(x.page !== 'settings', '① settingsBackPage="settings" ⇒ 返回后离开 settings（实测 ' + x.page + '）')
}
// ② player 槽位被写成下游 queue（本次用户报的 bug）
{
  const x = freshNav()
  x.page = 'player'; x.playerBackPage = 'queue'
  x.api.goPlayerBack()
  ok(x.page !== 'player' && x.page !== 'queue',
     '② playerBackPage="queue" ⇒ 返回后离开 player/queue（实测 ' + x.page + '）')
}
// ③ player 槽位被写成自己
{
  const x = freshNav()
  x.page = 'player'; x.playerBackPage = 'player'
  x.api.goPlayerBack()
  ok(x.page !== 'player', '③ playerBackPage="player" ⇒ 返回后离开 player（实测 ' + x.page + '）')
}
// ④ 槽位为空
{
  const x = freshNav()
  x.page = 'player'; x.playerBackPage = ''
  x.api.goPlayerBack()
  ok(x.page !== 'player', '④ playerBackPage="" ⇒ 返回后离开 player（实测 ' + x.page + '）')
}

// ============================================================
// 用户报的第二例死循环（2026-10-07）：播放页 ↔ 设置页 互相指向。
//   路径：播放页 --openSettings--> 设置页 --gotoPlayer--> 播放页 --返回--> 设置页 ...
//   形状与第一例（player↔queue）**完全相同**：两个页面互相把对方记成来处。
//   这次说明「只把 queue 放进 player 的下游」不够 —— 任何**互相可达**的两页都会踩。
// ============================================================
console.log('')
console.log('=== 播放页 ↔ 设置页：连按返回能否退出 ===')
{
  const x = makeNav()
  x.page = 'playlists'
  x.playerBackPage = ''
  x.settingsBackPage = ''
  x.api.gotoPlayer()          // 播放页（来处 playlists）
  x.api.openSettings()        // → 设置页（来处 player）
  x.api.gotoPlayer()          // → 播放页（来处 settings ← 这里埋下互相指向）
  const trail = []
  let exited = false
  for (let i = 0; i < 12; i++) {
    if (x.page === 'player') x.api.goPlayerBack()
    else if (x.page === 'settings') x.api.goBack()
    else { exited = true; break }
    trail.push(x.page)
    const cnt = trail.filter(p => p === x.page).length
    if (cnt >= 3) break
  }
  console.log('  轨迹: ' + trail.join(' → '))
  ok(exited, '连按返回能离开 player/settings 这对页面（最终 ' + x.page + '）')
  if (!exited) console.log('       🔴 卡在 player ↔ settings 之间')
}

// 槽位不应被互相污染
// ⚠️ 只拦**一个方向**就够了，两个方向都拦是错的：
//    · settingsBackPage="player" **合法** —— 用户确实从播放页进的设置，返回就该回播放页；
//    · playerBackPage="settings" **必须拒** —— 它与上一条合起来才构成 player↔settings 环。
//    第一版断言把前者也当失败 ⇒ 假红（"把正确的说成错的"）。
{
  const x = makeNav()
  x.page = 'playlists'
  x.playerBackPage = ''
  x.settingsBackPage = ''
  x.api.gotoPlayer()
  x.api.openSettings()
  ok(x.settingsBackPage === 'player',
     'openSettings 应记下合法来处 "player"（实测 "' + x.settingsBackPage + '"）')
  x.api.gotoPlayer()
  ok(x.playerBackPage !== 'settings',
     'gotoPlayer 不能把 "settings" 记成来处（否则成环），实测 "' + x.playerBackPage + '"')
}

console.log('')
if (bad) { console.log('  ' + pass + ' 项通过, bad=' + bad); process.exit(1) }
console.log('  ' + pass + ' 项通过')
