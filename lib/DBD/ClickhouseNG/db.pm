package DBD::ClickhouseNG::db;

# Responsibility: DBI database handle -- prepare/do/ping/disconnect,
# commit/rollback (no transactions), quote, handle attributes, and
# delegation of catalog methods to Catalog (archive/DESIGN.md §4).
# Internal deps: Placeholders, Types, Error, Catalog.
# Handle state: reads $dbh->{chng_client}. prepare() initialises the new
#   $sth's chng_segments, chng_params, chng_param_types, chng_param_bound,
#   chng_param_arrays, chng_param_array_types, chng_param_array_bound,
#   chng_rows and chng_data; st owns them from then on. Catalog owns
#   $dbh->{chng_dbms_version}.

use v5.40;
use Carp ();

use DBD::ClickhouseNG::Placeholders;
use DBD::ClickhouseNG::Types;
use DBD::ClickhouseNG::Error;
use DBD::ClickhouseNG::Catalog;

our $imp_data_size = 0;

sub prepare( $dbh, $statement, $attr = undef ) {
    my( $segments, $n_params );
    my $ok = eval {
        ( $segments, $n_params ) = DBD::ClickhouseNG::Placeholders::scan_placeholders( $statement );
        1;
    };
    unless( $ok ) {
        ( my $msg = $@ ) =~ s/\s+\z//;
        return $dbh->set_err( $DBI::stderr, $msg );
    }

    my( $outer, $sth ) = DBI::_new_sth( $dbh, { Statement => $statement } );
    $sth->{chng_segments}          = $segments;
    $sth->{chng_params}            = [];
    $sth->{chng_param_types}       = [];
    $sth->{chng_param_bound}       = {};
    $sth->{chng_param_arrays}      = [];
    $sth->{chng_param_array_types} = [];
    $sth->{chng_param_array_bound} = {};
    $sth->{chng_rows}              = undef;
    $sth->{chng_data}              = undef;
    $outer->STORE( NUM_OF_PARAMS => $n_params );

    return $outer;
}

sub do( $dbh, $statement, $attr = undef, @bind_values ) {
    if( @bind_values || ( defined $attr && %$attr ) ) {
        my $sth = $dbh->prepare( $statement, $attr ) or return undef;
        return $sth->execute( @bind_values );
    }

    my $res = $dbh->{chng_client}->query( DBD::ClickhouseNG::Error::utf8_bytes( $statement ) );
    unless( $res->{ok} ) {
        return DBD::ClickhouseNG::Error::report( $dbh, $res, 'do' );
    }

    my $body = $res->{body};
    ( my $trimmed = $body ) =~ s/\s+\z//;
    return -1 if $trimmed eq '';

    my $json = eval { $DBD::ClickhouseNG::JSON_CLASS->new->utf8->decode( $body ) };
    unless( $json ) {
        return $dbh->set_err( $DBI::stderr,
            "malformed JSON response from server: " . substr( DBD::ClickhouseNG::Error::decode_error_body( $body ), 0, 200 ) );
    }
    my $rows = $json->{rows} // 0;
    return $rows || '0E0';
}

sub ping( $dbh ) {
    return 0 unless $dbh->FETCH( 'Active' );
    return $dbh->{chng_client}->ping ? 1 : 0;
}

sub disconnect( $dbh ) {
    $dbh->STORE( Active => 0 );
    return 1;
}

sub commit( $dbh ) {
    warn "commit ineffective with AutoCommit enabled" if $dbh->FETCH( 'Warn' );
    return 1;
}

sub rollback( $dbh ) {
    warn "rollback ineffective with AutoCommit enabled" if $dbh->FETCH( 'Warn' );
    return 1;
}

sub quote( $dbh, $value, $data_type = undef ) {
    return DBD::ClickhouseNG::Types::quote_string( $value );
}

# Catalog / metadata methods are implemented in DBD::ClickhouseNG::Catalog;
# these delegates keep them in ::db, where DBI's method dispatch looks.
sub get_info         { return DBD::ClickhouseNG::Catalog::get_info( @_ ) }
sub data_sources     { return DBD::ClickhouseNG::Catalog::data_sources( @_ ) }
sub table_info       { return DBD::ClickhouseNG::Catalog::table_info( @_ ) }
sub column_info      { return DBD::ClickhouseNG::Catalog::column_info( @_ ) }
sub primary_key_info { return DBD::ClickhouseNG::Catalog::primary_key_info( @_ ) }
sub type_info_all    { return DBD::ClickhouseNG::Catalog::type_info_all( @_ ) }

sub STORE( $dbh, $attrib, $value ) {
    if( $attrib eq 'AutoCommit' ) {
        Carp::croak( 'DBD::ClickhouseNG does not support transactions (AutoCommit may not be disabled)' )
            unless $value;
        return $dbh->SUPER::STORE( $attrib, -901 );
    }
    if( $attrib =~ /\Achng_/ ) {
        $dbh->{$attrib} = $value;
        return 1;
    }
    return $dbh->SUPER::STORE( $attrib, $value );
}

sub FETCH( $dbh, $attrib ) {
    return 1 if $attrib eq 'AutoCommit';
    return $dbh->{$attrib} if $attrib =~ /\Achng_/;
    return $dbh->SUPER::FETCH( $attrib );
}

sub DESTROY( $dbh ) {
    $dbh->disconnect if $dbh->FETCH( 'Active' );
    return;
}
1;
