#!/usr/bin/perl
# 极简 mpv JSON-IPC 客户端：发一行 JSON，打印一行响应
# 用法: gdipc.pl <socket路径> <json>
use strict;
use warnings;
use IO::Socket::UNIX;

my $sock = shift @ARGV;
my $json = shift @ARGV;

if (!defined $sock || !defined $json) {
    print STDERR "usage: gdipc.pl <socket> <json>\n";
    exit 2;
}

my $s = IO::Socket::UNIX->new(Peer => $sock, Type => SOCK_STREAM)
    or do { print STDERR "connect failed: $!\n"; exit 3; };

print $s $json, "\n";
my $line = <$s>;
print $line if defined $line;
exit 0;
