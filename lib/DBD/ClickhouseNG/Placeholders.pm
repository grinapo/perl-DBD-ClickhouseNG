package DBD::ClickhouseNG::Placeholders;

# Responsibility: lexical scan of SQL text for `?` placeholders (respecting
# quotes, comments and $$-strings) and the execute_array() fast-path
# eligibility check (archive/DESIGN.md §7).
# Interface: scan_placeholders, is_batchable_insert.
# Internal deps: none. Pure functions, no state.

use v5.40;

# ---------------------------------------------------------------------------
# §7 placeholder scanning
# ---------------------------------------------------------------------------

sub _scan_quoted( $sql, $i, $len, $q ) {
    my $start = $i;
    $i++;
    while( $i < $len ) {
        my $c = substr( $sql, $i, 1 );
        if( $c eq '\\' && $i + 1 < $len ) {
            $i += 2;
            next;
        }
        if( $c eq $q ) {
            if( $i + 1 < $len && substr( $sql, $i + 1, 1 ) eq $q ) {
                $i += 2;
                next;
            }
            $i++;
            return ( substr( $sql, $start, $i - $start ), $i, 1 );
        }
        $i++;
    }
    return ( substr( $sql, $start ), $len, 0 );
}

# ClickHouse heredoc string literals: $tag$...$tag$, tag is \w* (REF).
# Recognized only when the full open+close pair is present; a lone '$' that
# doesn't start such a pair is ordinary text (ClickHouse has no other use of
# bare '$', but being permissive here costs nothing).
sub _scan_dollar_quoted( $sql, $i, $len ) {
    return undef unless substr( $sql, $i ) =~ /\A\$(\w*)\$/;
    my $tag   = $1;
    my $open  = "\$$tag\$";
    my $start = $i + length( $open );
    my $close = index( $sql, $open, $start );
    die "unterminated quote in statement\n" if $close == -1;
    my $end = $close + length( $open );
    return [ substr( $sql, $i, $end - $i ), $end ];
}

sub scan_placeholders( $sql ) {
    my @segments;
    my $n   = 0;
    my $cur = '';
    my $i   = 0;
    my $len = length $sql;

    while( $i < $len ) {
        my $c  = substr( $sql, $i, 1 );
        my $c2 = substr( $sql, $i, 2 );

        if( $c eq "'" || $c eq '"' || $c eq '`' ) {
            my( $text, $new_i, $closed ) = _scan_quoted( $sql, $i, $len, $c );
            die "unterminated quote in statement\n" unless $closed;
            $cur .= $text;
            $i = $new_i;
        }
        elsif( $c eq '$' && ( my $dq = _scan_dollar_quoted( $sql, $i, $len ) ) ) {
            my( $text, $new_i ) = @$dq;
            $cur .= $text;
            $i = $new_i;
        }
        elsif( $c2 eq '--' || $c eq '#' ) {
            my $nl = index( $sql, "\n", $i );
            if( $nl == -1 ) {
                $cur .= substr( $sql, $i );
                $i = $len;
            }
            else {
                $cur .= substr( $sql, $i, $nl - $i + 1 );
                $i = $nl + 1;
            }
        }
        elsif( $c2 eq '/*' ) {
            my $end = index( $sql, '*/', $i + 2 );
            if( $end == -1 ) {
                $cur .= substr( $sql, $i );
                $i = $len;
            }
            else {
                $cur .= substr( $sql, $i, $end - $i + 2 );
                $i = $end + 2;
            }
        }
        elsif( $c2 eq '??' ) {
            # Escape for a literal '?' (e.g. ClickHouse's ternary `cond ? a
            # : b`, which would otherwise be misread as a placeholder):
            # '??' in the source collapses to one literal '?', uncounted.
            $cur .= '?';
            $i += 2;
        }
        elsif( $c eq '?' ) {
            push @segments, $cur;
            $cur = '';
            $n++;
            $i++;
        }
        else {
            $cur .= $c;
            $i++;
        }
    }
    push @segments, $cur;

    return ( \@segments, $n );
}

# A statement is eligible for the execute_array() fast (batched) path only
# when every placeholder sits inside one literal "VALUES(...)" tuple with
# nothing but bare commas between them and nothing but the closing paren
# (and optional trailing ";") after it. This is deliberately conservative:
# segments preserve quoted text verbatim (unparsed), so anything looser
# risks miscounting parens hidden inside a string literal. A statement that
# fails this check simply falls back to one execute() per tuple -- a missed
# optimization, never a correctness risk.
sub is_batchable_insert( $segments, $n ) {
    return 0 if $n < 1;
    return 0 unless $segments->[0] =~ /\bVALUES\s*\(\s*\z/i;
    for my $i ( 1 .. $n - 1 ) {
        return 0 unless $segments->[$i] =~ /\A\s*,\s*\z/;
    }
    return 0 unless $segments->[$n] =~ /\A\s*\)\s*;?\s*\z/;
    return 1;
}

1;
