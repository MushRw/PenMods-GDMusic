#!/usr/bin/perl
# mkmp3.pl —— 生成静音 MP3（MPEG-1 Layer III, 44.1kHz, 128kbps, stereo）
#
# 为什么不用 WAV：真机这份 mpv 构建的 libavcodec 里 **没有 pcm_s16le 解码器**
# （实测 "Failed to initialize a decoder for codec 'pcm_s16le'"），
# 但 mp3 解码器在。所以用静音 MP3 让 mpv 真正「在放」，
# 从而让 gdnext.lua 的 add_timer(1,...) 的 index>=1 闸门打开。
#
# 帧结构: 417 字节/帧, 1152 样本/帧 @44100Hz ⇒ 38.28 帧/秒
# 用法: perl mkmp3.pl <out.mp3> <seconds>
use strict; use warnings;
my $out = shift // '/tmp/racetester-9/silence.mp3';
my $sec = shift // 300;

my $FPS   = 44100 / 1152;          # 38.28125
my $FRAME = 417;                   # 144*128000/44100 = 417 (无 padding)
my $nframes = int($sec * $FPS);

my $hdr = pack('C4', 0xFF, 0xFB, 0x90, 0x00);
my $frame = $hdr . ("\x00" x ($FRAME - 4));

open(my $f, '>:raw', $out) or die "open: $!";
for (1 .. $nframes) { print $f $frame; }
close $f;

my $bytes = $FRAME * $nframes;
printf("MP3 out=%s frames=%d bytes=%d nominal_sec=%.2f\n",
       $out, $nframes, $bytes, $nframes / $FPS);
exit 0;
