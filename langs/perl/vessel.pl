#!/usr/bin/perl
# Hello World Tree — Perl adapter.
#
# Perl is one of the four languages in the non-web toolchain (Rust + Lua + QML + Perl). Its job is text
# extraction: Perl was built for reading unstructured input and finding structure in it, which is
# exactly what an adapter does before any parser exists.
#
# The other three own different concerns and the split is deliberate:
#   Rust  the durable vessel — process, registry, serialisation
#   Lua   the embedding layer — a scripting surface inside the Rust host
#   QML   the shell — declarative UI over the Lua surface
#   Perl  the munging — the part that reads garbage and returns rows
#
# Regex-driven, on purpose. Where Python has an AST and Rust has a real parser, Perl's advantage is
# that it can extract something useful from a file that will not parse, which is most files.

use strict;
use warnings;
use utf8;

package HWT::Vessel;

our $VERSION = '0.1.0';

# ── Node and edge ─────────────────────────────────────────────────────────────
# Plain hashes rather than objects. A node is data; making it an object would need accessors for
# nothing, and the round-trip to JSON is the real interface.

sub node {
    my (%args) = @_;
    return {
        id     => $args{id},
        source => $args{source},
        kind   => $args{kind},
        label  => $args{label},
        line   => $args{line} // 0,
    };
}

sub edge {
    my (%args) = @_;
    return {
        from => $args{from},
        to   => $args{to},
        kind => $args{kind},
    };
}

# ── The declaration patterns ─────────────────────────────────────────────────
# One table, because a per-language extractor that hardcodes its own regexes is a per-language
# extractor that drifts. Adding a language means adding a row.

my %PATTERNS = (
    perl => {
        declare => qr/^\s*sub\s+([A-Za-z_]\w*)/,
        package => qr/^\s*package\s+([\w:]+)\s*;/,
        use     => qr/^\s*(?:use|require)\s+([\w:]+)/,
    },
    ruby => {
        declare => qr/^\s*(?:def|class|module)\s+([A-Za-z_]\w*[?!]?)/,
        require => qr/^\s*require(?:_relative)?\s+['"]([^'"]+)['"]/,
    },
    python => {
        declare => qr/^\s*(?:async\s+)?(?:def|class)\s+([A-Za-z_]\w*)/,
        import  => qr/^\s*(?:from\s+([\w.]+)\s+import|import\s+([\w.]+))/,
    },
);

# ── Extraction ───────────────────────────────────────────────────────────────

sub extract {
    my ($filename, $source, $language) = @_;
    $language //= 'perl';

    my $patterns = $PATTERNS{$language};
    die "no patterns for language '$language'" unless $patterns;

    my @nodes = (node(
        id    => "$filename:file",
        source => $language,
        kind  => 'file',
        label => $filename,
    ));
    my @edges;

    my $file_id = "$filename:file";
    my $line_no = 0;

    for my $line (split /\n/, $source) {
        $line_no++;

        # Comments are not declarations. Skipping them is what keeps the graph from lying.
        next if $line =~ /^\s*#/;

        if ($patterns->{declare} && $line =~ $patterns->{declare}) {
            my $name = $1;
            my $id   = "$filename:$name";
            push @nodes, node(
                id     => $id,
                source => $language,
                kind   => 'symbol',
                label  => $name,
                line   => $line_no,
            );
            push @edges, edge(from => $file_id, to => $id, kind => 'contains');
            next;
        }

        if ($patterns->{package} && $line =~ $patterns->{package}) {
            my $name = $1;
            my $id   = 'package:' . _flatten($name);
            push @nodes, node(id => $id, source => $language, kind => 'import', label => $name);
            push @edges, edge(from => $file_id, to => $id, kind => 'contains');
            next;
        }

        if ($patterns->{use} && $line =~ $patterns->{use}) {
            my $name = $1;
            my $id   = 'import:' . _flatten($name);
            push @nodes, node(id => $id, source => $language, kind => 'import', label => $name);
            push @edges, edge(from => $file_id, to => $id, kind => 'imports');
            next;
        }

        if ($patterns->{require} && $line =~ $patterns->{require}) {
            my $name = $1;
            my $id   = 'import:' . _flatten($name);
            push @nodes, node(id => $id, source => $language, kind => 'import', label => $name);
            push @edges, edge(from => $file_id, to => $id, kind => 'imports');
        }
    }

    return {
        language => $language,
        nodes    => \@nodes,
        edges    => \@edges,
    };
}

sub _flatten {
    my ($name) = @_;
    $name =~ s/[:.\/]/_/g;
    return $name;
}

# ── Merge ────────────────────────────────────────────────────────────────────
# Duplicate node ids collapse; duplicate edges collapse on the triple. The same import reached from
# four files is one node with four incoming edges, which is what makes the graph readable at all.

sub merge {
    my (@extractions) = @_;

    my %nodes;
    my @order;
    my %edges;
    my @edge_list;

    for my $ex (@extractions) {
        for my $n (@{ $ex->{nodes} }) {
            next if exists $nodes{ $n->{id} };
            $nodes{ $n->{id} } = $n;
            push @order, $n->{id};
        }

        for my $e (@{ $ex->{edges} }) {
            my $key = join("\x1f", $e->{from}, $e->{to}, $e->{kind});
            next if exists $edges{$key};
            $edges{$key} = 1;
            push @edge_list, $e;
        }
    }

    return {
        language => 'merged',
        nodes    => [ map { $nodes{$_} } @order ],
        edges    => \@edge_list,
    };
}

# ── Digest ───────────────────────────────────────────────────────────────────
# What an agent reads instead of the graph. Short, stable, and it names the counts rather than
# describing them.

sub digest {
    my ($ex) = @_;

    my %kinds;
    $kinds{ $_->{kind} }++ for @{ $ex->{nodes} };

    my $counts = join(', ', map { "$_=$kinds{$_}" } sort keys %kinds);
    return sprintf(
        '%s: %d nodes, %d edges [%s]',
        $ex->{language},
        scalar @{ $ex->{nodes} },
        scalar @{ $ex->{edges} },
        $counts,
    );
}

# ── Self-test ────────────────────────────────────────────────────────────────

sub selftest {
    my $sample = <<'SAMPLE';
package HWT::Demo;

use strict;
use Data::Dumper;

sub helper {
    my ($x) = @_;
    return $x + 1;
}

sub main {
    return helper(41);
}

1;
SAMPLE

    my $ex = extract('demo.pm', $sample, 'perl');
    print digest($ex), "\n";
    print "  $_->{kind}\t$_->{label}\n" for @{ $ex->{nodes} };

    my $merged = merge($ex, $ex);
    die "merge should deduplicate nodes" unless @{ $merged->{nodes} } == @{ $ex->{nodes} };
    die "merge should deduplicate edges" unless @{ $merged->{edges} } == @{ $ex->{edges} };

    print "selftest ok\n";
    return 0;
}

selftest() unless caller;

1;
