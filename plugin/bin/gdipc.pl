#!/usr/bin/perl
# gdipc.pl —— mpv JSON-IPC 极简客户端（纯 perl，设备自带 perl 5.x）
#
# 用法:
#   gdipc.pl <socket> status                  -> 打印 "pause|time-pos|duration|idle-active"
#   gdipc.pl <socket> pid                     -> 仅打印 mpv 自身 pid（唤醒锁要用）
#   gdipc.pl <socket> raw <一行JSON>           -> 发送并打印首个响应
#   gdipc.pl <socket> cmd <命令> [参数...]      -> 自动拼 JSON 发送
#
# cmd 模式下，纯数字/true/false/null 作为 JSON 原生值，其余按字符串转义。
# 例: gdipc.pl /tmp/gdmusic.sock cmd loadfile https://x/y.mp3
#     gdipc.pl /tmp/gdmusic.sock cmd set_property pause true
#     gdipc.pl /tmp/gdmusic.sock cmd seek 30 absolute

use strict;
use warnings;
use IO::Socket::UNIX;
use IO::Select;

my $sock = shift @ARGV;
my $mode = shift @ARGV;

if (!defined $sock || !defined $mode) {
    print STDERR "usage: gdipc.pl <socket> status | raw <json> | cmd <arg...>\n";
    exit 2;
}

sub esc {
    my $s = shift;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    return $s;
}

sub jval {
    my $s = shift;
    return $s if defined $s && $s =~ /^-?\d+(?:\.\d+)?$/;
    return $s if defined $s && ($s eq 'true' || $s eq 'false' || $s eq 'null');
    return '"' . esc(defined $s ? $s : '') . '"';
}

my $s = IO::Socket::UNIX->new(Peer => $sock, Type => SOCK_STREAM);
if (!$s) {
    print "ERR|connect|$!\n";
    exit 3;
}

my $sel = IO::Select->new($s);
$s->autoflush(1);

# ---------------------------------------------------------------- status
if ($mode eq 'status') {
    # 顺序很重要：设备上 mpv 主循环较忙，靠后的请求可能整轮不回包，
    # 所以把最关键的属性放在最前面。输出: pause|pos|dur|idle
    my @props = ('pause', 'time-pos', 'duration', 'idle-active');
    my %got;
    my $id = 0;
    for my $p (@props) {
        $id++;
        print $s qq({"command":["get_property","$p"],"request_id":$id}\n);
    }

    my $deadline = time() + 3;
    while (scalar(keys %got) < $id && time() < $deadline) {
        # 注意：这里必须用 next 而不是 last —— can_read 超时只代表这一轮暂时没数据，
        # 不代表后续属性不会回来（设备弱，mpv 回包可能慢）。
        next unless $sel->can_read(0.4);
        my $line = <$s>;
        last unless defined $line;   # 真 EOF 才退出
        next unless $line =~ /"request_id":(\d+)/;
        my $rid = $1;
        my $v = 'null';
        if ($line =~ /"data":\s*("[^"]*"|-?\d+(?:\.\d+)?|true|false|null)/) {
            $v = $1;
            $v =~ s/^"|"$//g;
        }
        $got{$rid} = $v;
    }

    print join('|', map { defined $got{$_} ? $got{$_} : 'null' } (1 .. $id)), "\n";
    exit 0;
}

# ---------------------------------------------------------------- pid
# mpv 自报的 pid 属性。不要用 pgrep -f 取：设备上 /userdisk/mpv/mpv 是包装脚本，
# 「包装进程」和「真正的 mpv」两个 cmdline 都含 --input-ipc-server，pgrep 会挑错 PID。
if ($mode eq 'pid') {
    print $s qq({"command":["get_property","pid"],"request_id":1}\n);
    my $line = '';
    if ($sel->can_read(3)) { $line = <$s>; }
    if (defined $line && $line =~ /"data":\s*(\d+)/) {
        print "$1\n";
        exit 0;
    }
    print "ERR|no-pid\n";
    exit 4;
}

# ---------------------------------------------------------------- raw
if ($mode eq 'raw') {
    my $j = shift @ARGV;
    if (!defined $j || $j eq '') { print "ERR|empty\n"; exit 2; }
    print $s $j, "\n";
    my $line = '';
    if ($sel->can_read(3)) { $line = <$s>; }
    print defined $line ? $line : "ERR|no-reply\n";
    exit 0;
}

# ---------------------------------------------------------------- cmd
if ($mode eq 'cmd') {
    my @a = @ARGV;
    if (!@a) { print "ERR|empty-cmd\n"; exit 2; }
    my $j = '{"command":[' . join(',', map { jval($_) } @a) . '],"request_id":1}';
    print $s $j, "\n";
    my $line = '';
    if ($sel->can_read(3)) { $line = <$s>; }
    print defined $line ? $line : "ERR|no-reply\n";
    exit 0;
}

print STDERR "unknown mode: $mode\n";
exit 2;
