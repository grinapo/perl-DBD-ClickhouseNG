use v5.38;
use Test::More;
no warnings 'once';

use DBD::ClickhouseNG::HTTP;

# DBD::ClickhouseNG::HTTP::LineReader splits a stream of raw byte chunks
# (as delivered by Net::HTTP's read_entity_body semantics: undef => error,
# 0 => EOF, -1 => no data yet/retry, otherwise bytes read) into lines,
# independent of any real socket. A fake "socket" here feeds canned chunks
# so the buffering/line-splitting logic can be exercised directly.

sub fake_sock( @chunks ) {
    return bless { chunks => [ @chunks ] }, 'FakeSock';
}

{   package FakeSock;
    sub read_entity_body {
        my $self = shift;
        return 0 unless @{ $self->{chunks} };
        $_[0] = shift @{ $self->{chunks} };
        return length $_[0];
    }
    sub close { return }
}

subtest 'whole lines delivered in one chunk' => sub {
    my $r = DBD::ClickhouseNG::HTTP::LineReader->new( fake_sock( "a\nb\nc\n" ) );
    is( $r->next_line, 'a' );
    is( $r->next_line, 'b' );
    is( $r->next_line, 'c' );
    is( $r->next_line, undef );
};

subtest 'a line split across multiple chunks' => sub {
    my $r = DBD::ClickhouseNG::HTTP::LineReader->new( fake_sock( 'ab', 'cd', "\n", 'ef' ) );
    is( $r->next_line, 'abcd' );
    is( $r->next_line, 'ef', 'trailing partial line at EOF, no newline needed' );
    is( $r->next_line, undef );
};

subtest 'multiple lines in one chunk' => sub {
    my $r = DBD::ClickhouseNG::HTTP::LineReader->new( fake_sock( "x\ny\nz" ) );
    is( $r->next_line, 'x' );
    is( $r->next_line, 'y' );
    is( $r->next_line, 'z' );
    is( $r->next_line, undef );
};

subtest 'CRLF line endings are stripped like LF' => sub {
    my $r = DBD::ClickhouseNG::HTTP::LineReader->new( fake_sock( "a\r\nb\r\n" ) );
    is( $r->next_line, 'a' );
    is( $r->next_line, 'b' );
    is( $r->next_line, undef );
};

subtest 'empty body is immediate EOF' => sub {
    my $r = DBD::ClickhouseNG::HTTP::LineReader->new( fake_sock() );
    is( $r->next_line, undef );
};

subtest 'trailing newline leaves no phantom empty line' => sub {
    my $r = DBD::ClickhouseNG::HTTP::LineReader->new( fake_sock( "only\n" ) );
    is( $r->next_line, 'only' );
    is( $r->next_line, undef );
};

subtest 'a -1 return (retry) from read_entity_body is retried, not treated as data or EOF' => sub {
    my $sock = bless { chunks => [ "-1", "a\n" ] }, 'RetrySock';
    no warnings 'redefine';
    local *RetrySock::read_entity_body = sub {
        my $self = shift;
        my $next = shift @{ $self->{chunks} };
        unless( defined $next ) {
            $_[0] = '';
            return 0;
        }
        if( $next eq '-1' ) {
            $_[0] = '';
            return -1;
        }
        $_[0] = $next;
        return length $next;
    };
    local *RetrySock::close = sub { return };
    my $r = DBD::ClickhouseNG::HTTP::LineReader->new( $sock );
    is( $r->next_line, 'a' );
    is( $r->next_line, undef );
};

subtest 'read_entity_body error (undef) raises rather than silently truncating' => sub {
    my $sock = bless {}, 'ErrSock';
    no warnings 'redefine';
    local *ErrSock::read_entity_body = sub { return undef };
    my $r = DBD::ClickhouseNG::HTTP::LineReader->new( $sock );
    eval { $r->next_line };
    like( $@, qr/streaming read failed/ );
};

done_testing;
