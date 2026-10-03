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
// 范围**故意收窄**：只查同一层缩进内的重复 property / function / id 声明。
// 早期版本还想查"未声明引用"和"括号配平"，结果全是误报 ——
//   · 未声明引用：controller.ncPhase 是跨文件注入的合法引用；
//     `Timer { id: ncPollTimer }` 也不是 property 声明形式。
//   · 括号配平：QML 里有正则字面量、模板字符串、转义引号，静态数括号称不上编译器
//     （项目里 playlist-ui/addpick 探针已经踩过，见正则感知版 countPairs）。
// 教训同探针那边：**检查器一旦开始靠启发式猜语义，误报就会淹没真信号**。
//
// 用法：node tools/qml-dupdecl.js <file.qml> [more.qml ...]
'use strict'
const fs = require('fs')

let bad = 0
for (const file of process.argv.slice(2)) {
  const lines = fs.readFileSync(file, 'utf8').split('\n')
  // key = 缩进深度 + 名字，value = 首次出现的行号（1-based）
  const seenProp = new Map()   // 顶层 property / function / signal
  const seenId = new Map()     // 同一父对象下的 id
  const problems = []

  lines.forEach((line, idx) => {
    const ln = idx + 1
    // 顶层（4 空格缩进）property / function / signal
    let m = line.match(/^ {4}(?:readonly\s+)?(property\s+\w+|property\s+var|function|signal)\s+(\w+)/)
    if (m) {
      const key = m[2]
      if (seenProp.has(key))
        problems.push(`第 ${ln} 行：重复的顶层 ${m[1]} "${key}"`
                      + `（首次声明在第 ${seenProp.get(key)} 行）`
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
