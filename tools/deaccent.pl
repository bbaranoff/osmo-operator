#!/usr/bin/perl
# deaccent.pl [fichiers...] — translittere accents FR + ponctuation typo vers
# ASCII, en place. Laisse intacts box-drawing, fleches et symboles (► ✓ ⚠ •).
# Sans argument : filtre stdin -> stdout.
use strict; use warnings; use utf8;
sub xlate {
  my $l = shift;
  $l =~ tr/àâäãáéèêëíìîïóòôöõúùûüçñýÿ/aaaaaeeeeiiiiooooouuuucnyy/;
  $l =~ tr/ÀÂÄÃÁÉÈÊËÍÌÎÏÓÒÔÖÕÚÙÛÜÇÑÝ/AAAAAEEEEIIIIOOOOOUUUUCNY/;
  $l =~ s/œ/oe/g; $l =~ s/Œ/OE/g; $l =~ s/æ/ae/g; $l =~ s/Æ/AE/g;
  $l =~ s/\x{00A0}/ /g; $l =~ s/\x{202F}/ /g;
  $l =~ s/[\x{2018}\x{2019}]/'/g; $l =~ s/[\x{201C}\x{201D}]/"/g;
  $l =~ s/\x{2026}/.../g; $l =~ s/[\x{2013}\x{2014}]/-/g;
  $l =~ s/\x{00AB}\s*/"/g; $l =~ s/\s*\x{00BB}/"/g;
  return $l;
}
if (!@ARGV) {
  binmode(STDIN,':utf8'); binmode(STDOUT,':utf8');
  print xlate($_) while <STDIN>; exit 0;
}
for my $f (@ARGV) {
  open(my $in,'<:utf8',$f) or do { warn "skip $f: $!\n"; next };
  local $/; my $c = <$in>; close $in;
  my $o = join('', map { xlate($_) } split(/(?<=\n)/, $c));
  next if $o eq $c;
  open(my $out,'>:utf8',$f) or do { warn "write $f: $!\n"; next };
  print $out $o; close $out;
  print "  fixed $f\n";
}
