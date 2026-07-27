#!/usr/bin/env perl
#
# fetch_abstracts.pl — populate _data/abstracts.yml for the hover-to-expand
# abstracts feature (js/pub-abstracts.js).
#
# WHY THIS RUNS SERVER-SIDE (not live in the browser):
#   The publications list would ideally pull abstracts live from the DOI, but
#   the abstracts simply aren't in the free, CORS-accessible DOI-metadata APIs
#   for most papers (Springer LNCS deposits no abstract to CrossRef/OpenAlex).
#   The one source that has them all — IACR ePrint — sends no CORS header, so a
#   browser can't fetch it. This script does the fetch once, server-side (no
#   CORS restriction), and bakes the results into _data/abstracts.yml, which
#   the page then reads instantly and offline.
#
# WHY YAML (not JSON):
#   Jekyll (via the github-pages / jekyll-build-pages engine) parses ALL _data
#   files through its YAML loader — including .json. Pretty-printed JSON whose
#   string values contain LaTeX backslash escapes is not reliably YAML-parseable
#   and breaks the build. So we emit a YAML file using literal block scalars
#   (`|`), which take the abstract text verbatim — no escaping pitfalls.
#
# WHAT IT DOES:
#   Reads _data/publications.yml. For each work it fetches, in order of
#   preference:
#     1. IACR ePrint (https://eprint.iacr.org/<eprint>) when an `eprint:` id is
#        present — full coverage, clean abstract markup with TeX math.
#     2. Springer landing page (https://doi.org/<doi> -> link.springer.com),
#        scraping <div id="Abs1-content"> — clean prose with proper math.
#     3. CrossRef (https://api.crossref.org/works/<doi>) as a last resort — its
#        JATS abstracts duplicate each equation (TeX + garbled fallback text).
#   Whatever it finds is written to _data/abstracts.yml, keyed by the eprint id
#   when available, otherwise the doi. Works with neither an abstract source nor
#   a hit are simply skipped; their entries stay un-expanded on the page and can
#   be filled in by hand (add a `"<eprint-or-doi>": |` block to the YAML).
#
# REQUIREMENTS: perl (with core JSON::PP, used only to read CrossRef) and curl.
# No CPAN modules. Existing entries in _data/abstracts.yml are preserved unless
# a fresh fetch supplies a value for the same key.
#
# USAGE (from the repo root):
#   perl scripts/fetch_abstracts.pl
#
use strict;
use warnings;
use utf8;                 # non-ASCII literals in this file are UTF-8
use JSON::PP;
use Encode qw(decode);

my $ROOT = ".";
my $FROM_JSON;                       # optional: seed from an existing JSON file
for my $arg (@ARGV) {
    if ($arg =~ /^--from-json=(.+)$/) { $FROM_JSON = $1; }
    else { $ROOT = $arg; }
}
my $PUBS = "$ROOT/_data/publications.yml";
my $OUT  = "$ROOT/_data/abstracts.yml";

# --- text safety + YAML block-scalar emission -------------------------------
# Make a string safe to place inside a YAML literal block scalar: normalise
# line breaks, turn tabs into spaces, and drop other control characters (which
# YAML forbids). Everything else — backslashes, $, quotes, colons — is literal.
sub sanitize {
    my $s = shift;
    return "" unless defined $s;
    $s =~ s/\r\n?/\n/g;                 # CRLF / CR -> LF
    $s =~ s/\t/    /g;                  # tabs -> spaces
    $s =~ s/[\x00-\x08\x0B-\x1F\x7F]//g; # C0 control chars except LF (0x0A)
    $s =~ s/[\x{0080}-\x{009F}]//g;      # C1 control chars (YAML forbids; often mojibake)
    $s =~ s/\x{FEFF}//g;                 # stray BOM / zero-width no-break space
    $s =~ s/[ \t]+\n/\n/g;              # trailing spaces per line
    $s =~ s/^\n+//; $s =~ s/\n+$//;     # leading/trailing blank lines
    return $s;
}

# One "key: |" literal block. Explicit indent indicator (2) so a content line
# that happens to begin with spaces can never confuse the parser.
sub yaml_block {
    my ($key, $val) = @_;
    my $out = "\"$key\": |2-\n";
    for my $line (split /\n/, sanitize($val), -1) {
        $out .= (length $line) ? "  $line\n" : "\n";
    }
    return $out;
}

# Minimal reader for the format this script emits, so existing/manual entries
# survive a re-run. Understands `"key": |...` blocks with 2-space indentation.
sub read_existing {
    my $path = shift;
    my %h;
    return %h unless -e $path;
    open(my $fh, "<:encoding(UTF-8)", $path) or return %h;
    my ($k, @buf);
    my $flush = sub {
        return unless defined $k;
        my $v = join("\n", @buf); $v =~ s/\n+$//;
        $h{$k} = $v; $k = undef; @buf = ();
    };
    while (my $l = <$fh>) {
        $l =~ s/\r?\n$//;
        if ($l =~ /^"(.+)":\s*\|[0-9+-]*\s*$/) { $flush->(); $k = $1; }
        elsif (defined $k && $l =~ /^  (.*)$/) { push @buf, $1; }
        elsif (defined $k && $l eq "")         { push @buf, ""; }
        elsif ($l =~ /^\s*#/ || $l eq "")      { next; }
        else { $flush->(); }
    }
    $flush->();
    close $fh;
    return %h;
}

# --- gather abstracts -------------------------------------------------------
my %abstracts;
my ($eprint_hits, $crossref_hits, $springer_hits, $misses) = (0, 0, 0, 0);

if ($FROM_JSON) {
    # Convert an existing JSON blob straight to YAML (no network fetch).
    open(my $jf, "<:encoding(UTF-8)", $FROM_JSON) or die "open $FROM_JSON: $!";
    local $/; my $raw = <$jf>; close $jf;
    my $decoded = eval { JSON::PP->new->utf8(0)->decode($raw) };
    die "invalid JSON in $FROM_JSON: $@" unless ref $decoded eq "HASH";
    %abstracts = %$decoded;
    printf STDERR "Seeded %d entries from %s\n", scalar(keys %abstracts), $FROM_JSON;
} else {
    %abstracts = read_existing($OUT);   # preserve prior/manual entries

    # minimal parse of publications.yml into a list of works
    open(my $pf, "<:encoding(UTF-8)", $PUBS) or die "open $PUBS: $!";
    my (@works, $cur);
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

    for my $w (@works) {
        my $key = $w->{eprint} // $w->{doi};
        next unless defined $key;
        my $abstract;
        if ($w->{eprint}) {
            $abstract = abstract_from_eprint($w->{eprint});
            $eprint_hits++ if $abstract;
        }
        if (!$abstract && $w->{doi}) {
            # Springer before CrossRef: its landing-page abstract renders math
            # cleanly, whereas CrossRef's JATS duplicates each equation as TeX
            # plus a garbled plain-text fallback.
            $abstract = abstract_from_springer($w->{doi});
            $springer_hits++ if $abstract;
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
}

# --- write YAML -------------------------------------------------------------
open(my $out, ">:encoding(UTF-8)", $OUT) or die "open $OUT: $!";
print $out "# Abstracts for the hover-to-expand feature (js/pub-abstracts.js).\n";
print $out "# Generated by scripts/fetch_abstracts.pl - keyed by eprint id, else doi.\n";
print $out "# Values are YAML literal block scalars, so abstract text is taken verbatim.\n\n";
for my $key (sort keys %abstracts) {
    my $v = $abstracts{$key};
    next unless defined $v && length sanitize($v);
    print $out yaml_block($key, $v);
}
close $out;

printf STDERR "\nWrote %s: %d entries%s\n", $OUT, scalar(keys %abstracts),
    $FROM_JSON ? "" : sprintf(" (%d ePrint, %d CrossRef, %d Springer, %d without an abstract)",
                              $eprint_hits, $crossref_hits, $springer_hits, $misses);

# --- helpers ----------------------------------------------------------------
sub strip_quotes { my $s = shift; $s =~ s/^["']//; $s =~ s/["']$//; return $s; }
sub snippet { my $t = shift // ""; return length($t) > 48 ? substr($t,0,45)."..." : $t; }

my $UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
       . "(KHTML, like Gecko) Chrome/124.0 Safari/537.36";

sub http_get {
    my $url = shift;
    my $body = `curl -sL --max-time 40 -A "$UA" "$url"`;
    return undef unless defined $body && length $body;
    return decode("UTF-8", $body, Encode::FB_DEFAULT);  # bytes -> characters
}

sub decode_entities {
    my $s = shift;
    $s =~ s/&#x([0-9a-fA-F]+);/chr(hex($1))/ge;  # hex numeric refs
    $s =~ s/&#(\d+);/chr($1)/ge;                  # decimal numeric refs
    $s =~ s/&lt;/</g;    $s =~ s/&gt;/>/g;
    $s =~ s/&quot;/"/g;  $s =~ s/&apos;/'/g;      $s =~ s/&nbsp;/ /g;
    $s =~ s/\x{00A0}/ /g;                          # non-breaking space -> space
    $s =~ s/&amp;/&/g;                             # ampersand last
    return $s;
}

# ePrint: the abstract is the <p style="white-space: pre-wrap;"> that directly
# follows the "Abstract" heading. Newlines inside are meaningful (pre-wrap).
sub abstract_from_eprint {
    my $id = shift;
    my $html = http_get("https://eprint.iacr.org/$id") or return undef;
    return undef unless $html =~ m{<h5[^>]*>\s*Abstract\s*</h5>\s*<p[^>]*>(.*?)</p>}s;
    my $a = $1;
    $a =~ s{<br\s*/?>}{\n}gi;
    $a =~ s/<[^>]+>//g;
    $a = decode_entities($a);
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
    $a =~ s/<jats:title>.*?<\/jats:title>//gs;
    $a =~ s/<[^>]+>//g;
    $a = decode_entities($a);
    $a =~ s/\s+/ /g;
    return (length $a) ? $a : undef;
}

# Springer landing page (last resort for papers with no ePrint and no CrossRef
# abstract): the abstract sits in <div ... id="Abs1-content"> ... </div>.
sub abstract_from_springer {
    my $doi = shift;
    my $html = http_get("https://doi.org/$doi") or return undef;
    # Capture the whole abstract section (up to </section>), not just the first
    # </div>: Springer wraps display equations in their own <div>, so stopping
    # at the first </div> would truncate the abstract at the first equation.
    return undef unless $html =~ m{id="Abs1-content"[^>]*>(.*?)</section>}s;
    my $a = $1;
    $a =~ s{</p>}{\n\n}gi;               # paragraph breaks
    $a =~ s{</div>}{\n\n}gi;             # equation / block breaks
    $a =~ s/<[^>]+>//g;                  # strip remaining (inline) tags
    $a = decode_entities($a);
    # Strip Springer author-query annotations that leak into the abstract markup:
    # a "query" marker (from <span class="u-sans-serif">query</span>) glued before
    # a "Please ..." sentence, e.g. "...queryPlease check and confirm ...codes.".
    # Real crypto abstracts never contain "queryPlease", so this is safe.
    $a =~ s/query\s*Please\b[^.]*\.\s*//gi;
    $a =~ s/[ \t]+\n/\n/g;               # trailing spaces per line
    $a =~ s/\n{3,}/\n\n/g;               # collapse blank-line runs
    $a =~ s/^\s+//; $a =~ s/\s+$//;
    return (length $a) ? $a : undef;
}
