#!/usr/bin/env perl
#
# fetch_abstracts.pl — populate _data/abstracts.json for the hover-to-expand
# abstracts feature (js/pub-abstracts.js).
#
# WHY THIS RUNS SERVER-SIDE (not live in the browser):
#   The publications list would ideally pull abstracts live from the DOI, but
#   the abstracts simply aren't in the free, CORS-accessible DOI-metadata APIs
#   for most papers (Springer LNCS deposits no abstract to CrossRef/OpenAlex).
#   The one source that has them all — IACR ePrint — sends no CORS header, so a
#   browser can't fetch it. This script does the fetch once, server-side (no
#   CORS restriction), and bakes the results into _data/abstracts.json, which
#   the page then reads instantly and offline.
#
# WHAT IT DOES:
#   Reads _data/publications.yml. For each work it fetches, in order of
#   preference:
#     1. IACR ePrint (https://eprint.iacr.org/<eprint>) when an `eprint:` id is
#        present — full coverage, clean abstract markup.
#     2. CrossRef (https://api.crossref.org/works/<doi>) as a fallback when
#        there's a `doi:` but no eprint — only some venues deposit abstracts.
#   Whatever it finds is written to _data/abstracts.json, keyed by the eprint id
#   when available, otherwise the doi. Works with neither an abstract source nor
#   a hit are simply skipped; their entries stay un-expanded on the page and can
#   be filled in by hand (add a "<eprint-or-doi>": "..." entry to the JSON).
#
# REQUIREMENTS: perl (with core JSON::PP) and curl. No CPAN modules, no build
# tooling. Existing manual entries in abstracts.json are preserved unless a
# fresh fetch supplies a value for the same key.
#
# USAGE (from the repo root):
#   perl scripts/fetch_abstracts.pl
#
use strict;
use warnings;
use JSON::PP;

my $ROOT   = shift(@ARGV) || ".";
my $PUBS   = "$ROOT/_data/publications.yml";
my $OUT    = "$ROOT/_data/abstracts.json";

# --- read existing output so manual/previous entries survive ----------------
my %abstracts;
if (-e $OUT) {
    open(my $fh, "<:encoding(UTF-8)", $OUT) or die "open $OUT: $!";
    local $/; my $raw = <$fh>; close $fh;
    if (defined $raw && $raw =~ /\S/) {
        my $decoded = eval { JSON::PP->new->utf8(0)->decode($raw) };
        %abstracts = %$decoded if ref $decoded eq "HASH";
    }
}

# --- minimal parse of publications.yml into a list of works -----------------
# Each work starts with a "- title:" line; we only need its eprint and doi.
open(my $pf, "<:encoding(UTF-8)", $PUBS) or die "open $PUBS: $!";
my @works;
my $cur;
while (my $line = <$pf>) {
    if ($line =~ /^\s*-\s+title:\s*(.+?)\s*$/) {
        push @works, $cur if $cur;
        $cur = { title => strip_quotes($1) };
    } elsif ($cur && $line =~ /^\s+eprint:\s*(.+?)\s*$/) {
        $cur->{eprint} = strip_quotes($1);
    } elsif ($cur && $line =~ /^\s+doi:\s*(.+?)\s*$/) {
        $cur->{doi} = strip_quotes($1);
    }
}
push @works, $cur if $cur;
close $pf;

sub strip_quotes {
    my $s = shift;
    $s =~ s/^["']//; $s =~ s/["']$//;
    return $s;
}

# --- fetch helpers ----------------------------------------------------------
sub http_get {
    my $url = shift;
    my $body = `curl -sL --max-time 30 "$url"`;
    return (defined $body && length $body) ? $body : undef;
}

sub decode_entities {
    my $s = shift;
    $s =~ s/&amp;/&/g;   $s =~ s/&lt;/</g;   $s =~ s/&gt;/>/g;
    $s =~ s/&quot;/"/g;  $s =~ s/&#0?39;/'/g; $s =~ s/&apos;/'/g;
    $s =~ s/&nbsp;/ /g;
    return $s;
}

# ePrint: the abstract is the <p style="white-space: pre-wrap;"> that directly
# follows the "Abstract" heading. Newlines inside are meaningful (pre-wrap).
sub abstract_from_eprint {
    my $id = shift;
    my $html = http_get("https://eprint.iacr.org/$id") or return undef;
    return undef unless $html =~ m{<h5[^>]*>\s*Abstract\s*</h5>\s*<p[^>]*>(.*?)</p>}s;
    my $a = $1;
    $a =~ s{<br\s*/?>}{\n}gi;   # keep explicit line breaks
    $a =~ s/<[^>]+>//g;         # drop any remaining tags
    $a = decode_entities($a);
    $a =~ s/\r//g;
    $a =~ s/[ \t]+\n/\n/g;      # trim trailing spaces on each line
    $a =~ s/^\s+//; $a =~ s/\s+$//;
    return (length $a) ? $a : undef;
}

# CrossRef: abstract (when present) is a JSON string of JATS XML.
sub abstract_from_crossref {
    my $doi = shift;
    my $json = http_get("https://api.crossref.org/works/$doi") or return undef;
    my $data = eval { JSON::PP->new->utf8(1)->decode($json) };
    return undef unless ref $data eq "HASH";
    my $a = $data->{message}{abstract};
    return undef unless defined $a && length $a;
    $a =~ s/<jats:title>.*?<\/jats:title>//gs;  # drop an "Abstract" label
    $a =~ s/<[^>]+>//g;                          # strip JATS tags
    $a = decode_entities($a);
    $a =~ s/\s+/ /g;
    $a =~ s/^\s+//; $a =~ s/\s+$//;
    return (length $a) ? $a : undef;
}

# --- main loop --------------------------------------------------------------
my ($eprint_hits, $crossref_hits, $misses) = (0, 0, 0);
for my $w (@works) {
    my $key = $w->{eprint} // $w->{doi};
    next unless defined $key;                 # nothing to key on
    my $abstract;
    if ($w->{eprint}) {
        $abstract = abstract_from_eprint($w->{eprint});
        $eprint_hits++ if $abstract;
    }
    if (!$abstract && $w->{doi}) {
        $abstract = abstract_from_crossref($w->{doi});
        $crossref_hits++ if $abstract;
    }
    if ($abstract) {
        $abstracts{$key} = $abstract;
        printf STDERR "  ok   %-14s %s\n", $key, snippet($w->{title});
    } else {
        $misses++;
        printf STDERR "  miss %-14s %s\n", $key, snippet($w->{title});
    }
}

sub snippet { my $t = shift // ""; return length($t) > 48 ? substr($t,0,45)."..." : $t; }

# --- write, pretty + stable so diffs stay readable --------------------------
open(my $out, ">:encoding(UTF-8)", $OUT) or die "open $OUT: $!";
print $out JSON::PP->new->utf8(0)->pretty->canonical->encode(\%abstracts);
close $out;

printf STDERR "\nWrote %s: %d entries (%d ePrint, %d CrossRef, %d without an abstract)\n",
    $OUT, scalar(keys %abstracts), $eprint_hits, $crossref_hits, $misses;
