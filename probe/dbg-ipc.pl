#!/usr/bin/perl
# 调试：批量发 5 个 get_property，打印每一行原始回包
use strict;
use warnings;
use IO::Socket::UNIX;
use IO::Select;

my $sock = shift @ARGV;
my $s = IO::Socket::UNIX->new(Peer => $sock, Type => SOCK_STREAM) or die "connect: $!";
$s->autoflush(1);

my @props = ('time-pos', 'duration', 'pause', 'volume', 'eof-reached');
my $id = 0;
for my $p (@props) {
    $id++;
    print $s qq({"command":["get_property","$p"],"request_id":$id}\n);
}
print "已发送 $id 条命令\n";

my $sel = IO::Select->new($s);
my $deadline = time() + 4;
my $n = 0;
while ($n < 5 && time() < $deadline) {
    if ($sel->can_read(0.3)) {
        my $l = <$s>;
        last unless defined $l;
        chomp $l;
        print "RAW[$n]: $l\n";
        $n++;
    }
}
print "收到 $n 条\n";
