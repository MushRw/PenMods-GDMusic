#!/usr/bin/perl
# instrument.pl —— 把隔离副本里的 write_file 精确替换成「带计时的等价实现」
#
# 用【字面量精确匹配】而不是正则懒惰匹配：早先用 (.*?)\nend\n 时，
# 懒惰匹配停在了 `if not f then return false end` 的那个 end 上，
# 生成出 `return true  local __t1 = ...` 的语法错误 ⇒ 整个脚本加载失败，
# mpv 里 gdnext 根本没跑起来（现象：wdur.txt 不存在、now.json 不增长）。
# 这类「注入把被测对象弄坏了」的坑，必须靠【注入后校验】兜住。
#
# 用法: perl instrument.pl <in.lua> <out.lua>
use strict; use warnings;

my $in  = shift or die "usage: instrument.pl <in> <out>";
my $out = shift or die "usage: instrument.pl <in> <out>";

local $/;
open(my $fh, '<', $in) or die "open $in: $!";
my $src = <$fh>;
close $fh;

my $orig = <<'ORIG';
local function write_file(p, s)
    local f = io.open(p, "w")
    if not f then return false end
    f:write(s)
    f:close()
    return true
end
ORIG

my $n = () = $src =~ /\Q$orig\E/g;
die "INSTRUMENT: 精确匹配到 $n 处（应为 1）—— 拒绝生成\n" unless $n == 1;

my $repl = <<'REPL';
local function write_file(p, s)
    local __t0 = mp.get_time()
    local f = io.open(p, "w")
    if not f then return false end
    f:write(s)
    f:close()
    local __t1 = mp.get_time()
    if p == NFILE then
        local __f = io.open("/tmp/racetester-9/wdur.txt", "a")
        if __f then
            __f:write(string.format("%.6f\n", (__t1 - __t0) * 1000000))
            __f:close()
        end
    end
    return true
end
REPL

$src =~ s/\Q$orig\E/$repl/ or die "INSTRUMENT: 替换失败\n";

# 注入后自校验：必须恰好各出现一次，且 return true 不再被拼接污染
my $c0 = () = $src =~ /local __t0 = mp\.get_time\(\)/g;
my $c1 = () = $src =~ /local __t1 = mp\.get_time\(\)/g;
my $cd = () = $src =~ /return true  local/g;
die "INSTRUMENT: 校验失败 __t0=$c0 __t1=$c1 污染=$cd\n"
    unless $c0 == 1 && $c1 == 1 && $cd == 0;

# 词法粗校验：花括号【增量】必须为 0。
# ⚠️ 不能对全文件做绝对配平检查 —— 源文件本身在注释/字符串里就含有
#    不配平的 { }（如注释里的 `{"A","B"}` 与说明文字），绝对检查会误报。
#    正确做法是只校验「注入前后的差值」。
my $ob0 = () = $orig =~ /\{/g;  my $cb0 = () = $orig =~ /\}/g;
my $ob1 = () = $repl =~ /\{/g;  my $cb1 = () = $repl =~ /\}/g;
my $do = $ob1 - $ob0;
my $dc = $cb1 - $cb0;
die "INSTRUMENT: 花括号增量不配平 (delta_open=$do delta_close=$dc)\n" unless $do == $dc;
die "INSTRUMENT: 出现换行被吞（return true 后无换行）\n"
    if $src =~ /return true[^\n]*local __t/;

# 结构校验：注入后 write_file 函数体应保持闭合，且未改动其它函数
my $nf = () = $src =~ /^local function /gm;
my $nf0 = () = do { local $/; open(my $g,'<',$in) or die; my $o=<$g>; close $g; $o } =~ /^local function /gm;
die "INSTRUMENT: 顶层函数数量变化 $nf0 -> $nf\n" unless $nf == $nf0;

open(my $of, '>', $out) or die "open $out: $!";
print $of $src;
close $of;
print "INSTRUMENT ok: 精确替换 1 处，__t0=$c0 __t1=$c1 污染=$cd brace_delta=$do/$dc funcs=$nf0->$nf\n";
exit 0;
