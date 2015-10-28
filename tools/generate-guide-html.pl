#!/usr/bin/perl

use strict;
use File::Slurp;
use IPC::Run3;

my $index = read_file("content/admin/guide/index.md");
my @files;
my %refs;
my $idx = 0;

while ($index =~ /\[.*?\]\[(.*?)\]/g) {
    $refs{$1} = $idx++;
}

while ($index =~ /\[(.*?)\]:\s*(\S+)/g) {
    $files[$refs{$1}] = $2 if exists $refs{$1};
}

my @css = ("static/shared/css/docs.style.min.css", "static/shared/css/pygments.min.css");
my $css = join("\n", map {read_file($_)} @css);

$css.= "
.TOC { float: left; width: 20% }
#content { float: left; width: 70%; }
code {
    background: inherit;
    color: inherit;
    margin: 0px;
    padding: 0px;
    font-size: inherit !important;
    font-family: inherit;
}
";
$css =~ s/\n/\n    /g;

my $in;

$in="---
title: ejabberd Installation and Operation Guide
bodyclass: nocomment
HTML header: <style>$css</style>
---

{{TOC}}
<div id='content'>
";

$idx = 1;
for (@files) {
    s/\/$/.md/;
    my $content = read_file("content".$_);
    $content =~ s/^---.*?---\s*//s;
    $content =~ s/\[(.*?)\]\[(.*?)\]/[$1][$idx$2]/g;
    $content =~ s/\[(.*?)\]:/[$idx$1]:/g;
    $in.= "$content\n\n";
    $idx++;
}
my $out;
run3("multimarkdown", \$in, \$out, \undef);

$out =~ s/class="TOC"/id="sidebar" class="TOC"/;

write_file("guide.html", $out);
