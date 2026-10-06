#!/usr/bin/env node
// QML 重复声明检查 —— 只做一件事，但这件事**只有它能做**。
//
// 起因（2026-10-03 23:2x 真机事故四）：修「扫码没反应」时把 `property string
// ncQrFile` 既插进了属性区、又在替换 ncQrImgPath() 时于函数区中间插了一份。
// 结果：10 个源码探针**全绿**（它们只做字符串/求值断言，不解析 QML 结构），
// 但真机 qmlscene 一跑就报
//     file:///tmp/shot-check.qml:1638 Duplicate property name
// 整个插件页打不开 —— 而这类错误在 node 求值层完全不可见。
//
// 📌 教训：**源码探针全绿 ≠ QML 能加载**。凡是"新增顶层 property"的动作，
//    必须过这一关（或者部署前先真机 qmlscene 一次）。
//
// 范围**故意收窄**：只查同一层缩进内的重复 property / function / signal / id 声明。
// 早期版本还想查"未声明引用"和"括号配平"，结果全是误报 ——
//   · 未声明引用：controller.ncPhase 是跨文件注入的合法引用；
//     `Timer { id: ncPollTimer }` 也不是 property 声明形式。
//   · 括号配平：QML 里有正则字面量、模板字符串、转义引号，静态数括号称不上编译器
//     （项目里 playlist-ui/addpick 探针已经踩过，见正则感知版 countPairs）。
// 教训同探针那边：**检查器一旦开始靠启发式猜语义，误报就会淹没真信号**。
//
// ⚠️ 为什么 key 里**必须留缩进**，不能只按名字去重（这是实测出来的，不是理论）：
//   MediaBridge.qml 里 `property Connections sessionLinks: Connections {`（:668）
//   块内有 9 个 `function onPlayRequested()` / `onPauseRequested()` / …（:672-680），
//   它们是 **Connections 的信号处理器**，与根对象上的同名方法（:521-604）是**两个东西**。
//   只按名字去重 ⇒ 这 9 条全部误报 ⇒ 门禁一上线就天天红，**信号直接被淹没**
//   （这正是头注释里"误报会淹没真信号"的现实版）。实测：name-only 会报 9 条假阳性。
//
// 用法：node tools/qml-dupdecl.js <file.qml> [more.qml ...]
//
// ⚠️ 调用方必须自己展开好通配符。**Node 不做 glob**：直接传 `foo/*.qml` 进来的是
//    字面量字符串 `foo/*.qml`，fs.readFileSync 会 ENOENT 抛栈 —— 而崩栈本身没有任何
//    信息量，看起来像"脚本坏了"而不是"参数给错了"。
//  · bash（deploy.sh 用）：写 "$L"/qml/*.qml，**由 bash 展开**，正确。
//  · Windows PowerShell：Node 不会展开，必须先展开成数组再传，例如
//      $files = (Get-ChildItem plugin/qml -Filter *.qml -File) `
//             + (Get-ChildItem plugin/qml/pages -Filter *.qml -File) `
//             + (Get-ChildItem plugin/qml/components -Filter *.qml -File)
//      node tools/qml-dupdecl.js ($files | ForEach-Object { $_.FullName })
//
// ⚠️ 为什么不"顺手在 Node 里 glob 一遍"：bash 传进来的是**已经展开好的 17 个具体
//    文件名**，Node 若再去 glob，可能匹配出没打算检查的文件（例如备份目录、.tmp/）。
//    门禁的第一职责是"坏掉的输入立刻可见"，不是猜 —— 宁可多报，不可悄悄改变检查范围。
'use strict'
const fs = require('fs')

const argv = process.argv.slice(2)

// 🔴 坏输入必须与"检查到重复声明"（exit 1）区分开：CI 里 1 = 门禁正常拦下了问题，
//    2 = 根本没检查成功。后者绝不能冒充前者，否则一道红门禁会被误读成"有 bug，去修"。
const globs = argv.filter(a => /[*?]/.test(a))
if (globs.length) {
  console.error('❌ 参数里有未展开的通配符：' + globs.join(' '))
  console.error('   Node 不会展开 glob，会把它当字面文件名 → ENOENT。')
  console.error('   bash：写 ' + '"$L"/qml/*.qml' + '（由 bash 展开）')
  console.error('   PowerShell：先展开成数组再传，例：')
  console.error('     $files = (Get-ChildItem plugin/qml -Filter *.qml -File) `')
  console.error('            + (Get-ChildItem plugin/qml/pages -Filter *.qml -File) `')
  console.error('            + (Get-ChildItem plugin/qml/components -Filter *.qml -File)')
  console.error('     node tools/qml-dupdecl.js ($files | ForEach-Object { $_.FullName })')
  process.exit(2)
}

let bad = 0
for (const file of argv) {
  // 文件真不存在也要人话报错，别让 fs 抛栈（崩栈无法区分"路径打错"与"文件真没了"）
  if (!fs.existsSync(file)) {
    console.error('❌ 找不到文件：' + file)
    process.exit(2)
  }
  const lines = fs.readFileSync(file, 'utf8').split('\n')
  // key = 缩进宽度 + 名字，value = 首次出现的行号（1-based）
  const seenProp = new Map()   // 同一层缩进内的 property / function / signal
  const seenId = new Map()     // 同一父对象下的 id
  const problems = []

  // 声明行：任意缩进 + 可选 default/required 限定词 + 可选 readonly。
  // 限定词是 Qt 5.15/6 的合法语法，写漏了就等于没查这一类：
  //   default property alias content: children   // ListView 之类
  //   required property int currentIndex         // 组件入参
  // 2026-10-05 补齐：旧正则只认 `(?:readonly\s+)?`，这两个限定词一律漏检。
  // 类型名用 \w+ 是刻意的（比写死 string|var|int 健壮），property alias 也就顺带覆盖了。
  const DECL = /^(\s+)(?:(?:default|required)\s+)?(?:readonly\s+)?(property\s+\w+|function|signal)\s+(\w+)/
  // 行尾注释与字符串里的 "property" 不该被当成声明 —— 但声明行本身以
  // `property <type> <name>` 开头，后面跟 `:` 或 `(`，加个宽松收尾约束即可。
  lines.forEach((line, idx) => {
    const ln = idx + 1
    let m = line.match(DECL)
    if (m && !/^\s*(?:\/\/|#)/.test(line)) {
      // 缩进宽度（制表符按 1 计：本项目 QML 全用空格缩进，已核对无 tab）
      const key = m[1].length + ':' + m[3]
      if (seenProp.has(key))
        problems.push(`第 ${ln} 行：重复的 ${m[2]} "${m[3]}"`
                      + `（同缩进层级(${m[1].length} 空格)内首次声明在第 ${seenProp.get(key)} 行）`
                      + ` —— QML 报 Duplicate property name，页面直接打不开`)
      else seenProp.set(key, ln)
    }
    // 任意缩进的 id: xxx —— 同缩进层级内不应重复
    m = line.match(/^(\s*)id:\s*(\w+)\s*$/)
    if (m) {
      const key = m[1].length + ':' + m[2]
      if (seenId.has(key))
        problems.push(`第 ${ln} 行：重复的 id "${m[2]}"（同缩进层级内首次在第 ${seenId.get(key)} 行）`)
      else seenId.set(key, ln)
    }
  })

  if (problems.length) {
    bad += problems.length
    console.log('❌ ' + file)
    for (const p of problems) console.log('   - ' + p)
  } else {
    console.log('ok  ' + file)
  }
}

console.log('')
console.log(`files=${process.argv.length - 2} bad=${bad}`)
process.exit(bad > 0 ? 1 : 0)
