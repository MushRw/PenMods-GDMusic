#!/usr/bin/perl
# overhead.pl —— 量化测量工具自身开销，避免把「时钟调用成本」当成真实写窗口
use strict; use warnings;
use Time::HiRes qw(time);
sub pct { my ($s,$p)=@_; my $i=int(($p/100)*$#$s); $i=0 if $i<0; $i=$#$s if $i>$#$s; return $s->[$i]; }
sub stats { my ($n,$a)=@_; my @s=sort{$a<=>$b}@$a; my $sum=0; $sum+=$_ for @s;
  printf("OVH %-18s n=%d min=%.2f p50=%.2f p95=%.2f max=%.2f (us)\n",$n,scalar(@s),$s[0],pct(\@s,50),pct(\@s,95),$s[-1]); }

my $N = shift // 5000;

# (a) 纯 time() 两次调用成本（无任何文件操作）
my @a;
for (1..$N) { my $t0=time; my $t1=time; push @a,($t1-$t0)*1e6; }
stats('time_pair',\@a);

# (b) open+close，不写任何字节（隔离出「open 截断 + close」本身）
my @b;
for (1..$N) { my $t0=time; open(my $f,'>','/tmp/racetester-9/ovh.json') or die; close($f); push @b,(time-$t0)*1e6; }
stats('open_close_nowrite',\@b);

# (c) 目标路径：open+write205+close（与 wtest.pl 同形，用于交叉核对）
my $p = 'x' x 205;
my @c;
for (1..$N) { my $t0=time; open(my $f,'>','/tmp/racetester-9/ovh.json') or die; print $f $p; close($f); push @c,(time-$t0)*1e6; }
stats('open_write_close',\@c);
exit 0;
