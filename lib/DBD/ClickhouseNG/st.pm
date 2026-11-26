package DBD::ClickhouseNG::st;

# Responsibility: DBI statement handle -- parameter binding, execute
# (buffered and streaming), execute_array (batched fast path and per-tuple
# loop), fetch/finish and statement attributes (archive/DESIGN.md §5).
# Internal deps: Placeholders, Types, Error; HTTP only via
#   $sth->{Database}{chng_client}.
# Handle state ($sth keys, all owned here unless noted):
#   binding:   chng_segments (set by db::prepare, read-only here),
#              chng_params, chng_param_types, chng_param_bound,
#              chng_param_arrays, chng_param_array_types,
#              chng_param_array_bound (initialised by db::prepare)
#   metadata:  chng_types, chng_ch_types, chng_precision, chng_scale,
#              chng_nullable, chng_converters
#   results:   chng_data, chng_pos, chng_rows
#   streaming: chng_reader, chng_batch_rows, chng_stream_error
#   user attr: chng_retry_on_error
#   reads $sth->{Database}{chng_client} and {chng_fetch_batch_rows} (set by dr).

use v5.40;
use DBD::ClickhouseNG::Placeholders;
use DBD::ClickhouseNG::Types;
use DBD::ClickhouseNG::Error;

our $imp_data_size = 0;

sub bind_param( $sth, $param, $value, $attr = undef ) {
    my $n = $sth->FETCH( 'NUM_OF_PARAMS' );
    return $sth->set_err( $DBI::stderr, "Cannot bind param $param, statement has $n parameters" )
        unless $param >= 1 && $param <= $n;

    my $type = DBD::ClickhouseNG::Types::extract_bind_type( $attr );

    $sth->{chng_params}[$param - 1] = $value;
    $sth->{chng_param_types}[$param - 1] = $type if defined $type;
    $sth->{chng_param_bound}{$param} = 1;
    return 1;
}

sub bind_param_array( $sth, $param, $value, $attr = undef ) {
    my $n = $sth->FETCH( 'NUM_OF_PARAMS' );
    return $sth->set_err( $DBI::stderr, "Cannot bind param $param, statement has $n parameters" )
        unless $param >= 1 && $param <= $n;

    my $type = DBD::ClickhouseNG::Types::extract_bind_type( $attr );

    $sth->{chng_param_arrays}[$param - 1] = $value;
    $sth->{chng_param_array_types}[$param - 1] = $type if defined $type;
    $sth->{chng_param_array_bound}{$param} = 1;
    return 1;
}

# Shared by the buffered and streaming execute() paths: apply a
# {name,type} meta array to the sth's DBI/driver-private metadata
# attributes and return the per-column value converters. Returns undef
# (with $sth->err set) if the column count changed between executions
# of a prepared statement.
sub _apply_result_meta( $sth, $meta ) {
    if( !defined $sth->{chng_ch_types} ) {
        $sth->STORE( NUM_OF_FIELDS => scalar @$meta );
        $sth->STORE( NAME          => [ map { $_->{name} } @$meta ] );
    }
    else {
        return $sth->set_err( $DBI::stderr, "result column count changed between executions" )
            unless scalar( @$meta ) == $sth->FETCH( 'NUM_OF_FIELDS' );
    }

    my $chop_blanks = $sth->FETCH( 'ChopBlanks' );

    my( @types, @precision, @scale, @nullable, @converters );
    for my $col ( @$meta ) {
        my( $sql_type, $prec, $sc, $null ) = DBD::ClickhouseNG::Types::map_ch_type( $col->{type} );
        push @types, $sql_type;
        push @precision, $prec;
        push @scale, $sc;
        push @nullable, $null;
        push @converters, ( $chop_blanks && DBD::ClickhouseNG::Types::is_fixedstring_ch_type( $col->{type} ) )
            ? \&DBD::ClickhouseNG::Types::chop_nul
            : DBD::ClickhouseNG::Types::value_converter( $sql_type );
    }
    $sth->{chng_ch_types}  = [ map { $_->{type} } @$meta ];
    $sth->{chng_types}     = \@types;
    $sth->{chng_precision} = \@precision;
    $sth->{chng_scale}     = \@scale;
    $sth->{chng_nullable}  = \@nullable;

    return \@converters;
}

sub execute( $sth, @bind_values ) {
    if( @bind_values ) {
        for my $i ( 1 .. @bind_values ) {
            $sth->bind_param( $i, $bind_values[$i - 1] ) or return undef;
        }
    }

    my $n      = $sth->FETCH( 'NUM_OF_PARAMS' );
    my $params = $sth->{chng_params};
    return $sth->set_err( $DBI::stderr,
        "execute called with " . scalar( @$params ) . " bound values, statement has $n parameters" )
        unless @$params == $n;

    my $bound = $sth->{chng_param_bound} // {};
    for my $i ( 1 .. $n ) {
        return $sth->set_err( $DBI::stderr, "bind_param not called for parameter $i" )
            unless $bound->{$i};
    }

    my $segments = $sth->{chng_segments};
    my $types    = $sth->{chng_param_types};

    my $sql = $segments->[0];
    my %url_params;
    for my $i ( 1 .. $n ) {
        my $value = $params->[$i - 1];
        my $type  = DBD::ClickhouseNG::Types::infer_ch_type( $value, $types->[$i - 1] );
        $sql .= "{p$i:$type}" . $segments->[$i];
        $url_params{"param_p$i"} = DBD::ClickhouseNG::Types::encode_param( $value, $type );
    }

    # A re-execute is a clean slate: any streaming error left un-surfaced
    # by an abandoned previous result (caller stopped fetching without
    # exhausting the stream or calling finish()) belongs to that old
    # result, not this new execute() -- discard it before finish()
    # (below) gets a chance to resurface it against this execute.
    delete $sth->{chng_stream_error};
    $sth->finish;

    my $batch_rows = $sth->{chng_fetch_batch_rows} // $sth->{Database}{chng_fetch_batch_rows};
    if( $batch_rows ) {
        return $sth->set_err( $DBI::stderr, 'chng_fetch_batch_rows must be a positive integer' )
            unless $batch_rows =~ /\A[1-9][0-9]*\z/;
        return _execute_streaming( $sth, $sql, \%url_params, $batch_rows );
    }

    my $res = $sth->{Database}{chng_client}->query( DBD::ClickhouseNG::Error::utf8_bytes( $sql ), \%url_params );
    unless( $res->{ok} ) {
        return DBD::ClickhouseNG::Error::report( $sth, $res, 'execute' );
    }

    my $body = $res->{body};
    ( my $trimmed = $body ) =~ s/\s+\z//;
    if( $trimmed eq '' ) {
        $sth->{chng_rows} = -1;
        $sth->{chng_data} = undef;
        $sth->STORE( Active => 0 );
        return -1;
    }

    my $json = eval { $DBD::ClickhouseNG::JSON_CLASS->new->utf8->decode( $body ) };
    unless( $json ) {
        return $sth->set_err( $DBI::stderr,
            "malformed JSON response from server: " . substr( DBD::ClickhouseNG::Error::decode_error_body( $body ), 0, 200 ) );
    }

    my $meta       = $json->{meta} // [];
    my $converters = _apply_result_meta( $sth, $meta ) or return undef;

    my $data = $json->{data} // [];
    for my $row ( @$data ) {
        for my $i ( 0 .. $#$converters ) {
            next unless $converters->[$i];
            next unless defined $row->[$i];
            $row->[$i] = $converters->[$i]->( $row->[$i] );
        }
    }

    $sth->{chng_data} = $data;
    $sth->{chng_pos}  = 0;
    $sth->{chng_rows} = $json->{rows} // scalar @$data;
    $sth->STORE( Active => 1 );

    return $sth->{chng_rows} || '0E0';
}

# LineReader::next_line dies on a transport-level read failure (a
# connection reset mid-body is a real failure mode even under
# wait_end_of_query=1 -- the body is server-buffered, but still travels
# over a fragile socket). Both streaming callers below go through this
# instead of calling next_line directly, so such a failure becomes a
# normal set_err()/undef return like every other transport failure in
# this driver, rather than an uncaught die escaping fetch()/execute()
# regardless of RaiseError.
sub _reader_next_line( $reader ) {
    my $line = eval { $reader->next_line };
    if( $@ ) {
        ( my $msg = $@ ) =~ s/\s+\z//;
        return ( 0, $msg );
    }
    return ( 1, $line );
}

# Streaming counterpart of execute(): requests
# JSONCompactEachRowWithNamesAndTypes over a dedicated Net::HTTP(S)
# connection (see HTTP::query_stream) and reads only the two header
# lines (names, types) up front -- data rows are pulled in
# chng_fetch_batch_rows-sized batches by fetch()/_refill_streaming_batch
# below, so client memory stays bounded to roughly one batch regardless
# of result size. Row count is unknown ahead of the full scan, so rows()
# returns -1 for a streamed statement, same as DBI's "not known" convention.
sub _execute_streaming( $sth, $sql, $url_params, $batch_rows ) {
    my $res = $sth->{Database}{chng_client}->query_stream( DBD::ClickhouseNG::Error::utf8_bytes( $sql ), $url_params );
    unless( $res->{ok} ) {
        return DBD::ClickhouseNG::Error::report( $sth, $res, 'execute' );
    }

    my $reader = $res->{reader};

    my( $ok1, $names_line ) = _reader_next_line( $reader );
    unless( $ok1 ) {
        $reader->close;
        return $sth->set_err( $DBI::stderr, "streaming transport error: $names_line" );
    }
    my( $ok2, $types_line ) = _reader_next_line( $reader );
    unless( $ok2 ) {
        $reader->close;
        return $sth->set_err( $DBI::stderr, "streaming transport error: $types_line" );
    }

    # A statement with no result set (INSERT, DDL, ...) gets a clean
    # empty body -- no header lines at all -- same as the buffered
    # path's `$trimmed eq ''` case. Only *one* header line present is
    # the genuine truncation/malformed case.
    if( !defined $names_line && !defined $types_line ) {
        $reader->close;
        $sth->{chng_rows} = -1;
        $sth->{chng_data} = undef;
        $sth->STORE( Active => 0 );
        return -1;
    }
    unless( defined $names_line && defined $types_line ) {
        $reader->close;
        return $sth->set_err( $DBI::stderr, 'malformed streaming response: missing header lines' );
    }

    my $names     = eval { $DBD::ClickhouseNG::JSON_CLASS->new->utf8->decode( $names_line ) };
    my $types_raw = eval { $DBD::ClickhouseNG::JSON_CLASS->new->utf8->decode( $types_line ) };
    unless( $names && $types_raw ) {
        $reader->close;
        return $sth->set_err( $DBI::stderr, 'malformed JSON response from server (streaming header)' );
    }

    my $meta       = [ map { { name => $names->[$_], type => $types_raw->[$_] } } 0 .. $#$names ];
    my $converters = _apply_result_meta( $sth, $meta );
    unless( $converters ) {
        $reader->close;
        return undef;
    }

    $sth->{chng_reader}     = $reader;
    $sth->{chng_converters} = $converters;
    $sth->{chng_batch_rows} = $batch_rows;
    $sth->{chng_data}       = [];
    $sth->{chng_pos}        = 0;
    $sth->{chng_rows}       = -1;
    $sth->STORE( Active => 1 );

    return -1;
}

# Pull up to chng_batch_rows more decoded/converted rows from the
# streaming reader into chng_data. Closes and clears chng_reader once
# the stream is exhausted (or a malformed row/transport error forces an
# early stop), so a subsequent fetch() sees a plain empty-buffer EOF.
#
# A transport error mid-batch is stashed in chng_stream_error rather
# than reported via set_err() here: DBI resets err/errstr at the start
# of every new top-level method dispatch, so if this batch already has
# good rows to deliver, set_err() here would be invisibly wiped out
# before the *next* fetch() call (the one that actually returns undef)
# ever runs -- an error that fires but is never observable by the
# caller. fetch() re-applies the stashed error via set_err() on the
# call where it actually has nothing left to return.
sub _refill_streaming_batch( $sth ) {
    my $reader     = $sth->{chng_reader};
    my $converters = $sth->{chng_converters};
    my $batch_rows = $sth->{chng_batch_rows};

    # A blank line (if the server ever emits one) is skipped without
    # counting toward the batch, so end-of-stream is detected only from
    # next_line() itself returning undef (or a malformed row forcing an
    # early stop) -- never inferred from an under-filled batch, which a
    # skipped blank line could otherwise cause spuriously.
    my @rows;
    my $done = 0;
    while( @rows < $batch_rows ) {
        my( $ok, $line ) = _reader_next_line( $reader );
        unless( $ok ) {
            $sth->{chng_stream_error} = [ $DBI::stderr, "streaming transport error: $line", 'S1000' ];
            $done = 1;
            last;
        }
        unless( defined $line ) {
            $done = 1;
            last;
        }
        next unless length $line;

        my $row = eval { $DBD::ClickhouseNG::JSON_CLASS->new->utf8->decode( $line ) };
        unless( $row ) {
            $sth->{chng_stream_error} =
                [ $DBI::stderr, 'malformed JSON response from server (streaming row)', 'S1000' ];
            $done = 1;
            last;
        }

        for my $i ( 0 .. $#$converters ) {
            next unless $converters->[$i];
            next unless defined $row->[$i];
            $row->[$i] = $converters->[$i]->( $row->[$i] );
        }
        push @rows, $row;
    }

    if( $done ) {
        $reader->close;
        $sth->{chng_reader} = undef;
    }

    $sth->{chng_data} = \@rows;
    $sth->{chng_pos}  = 0;
    return;
}

# execute_array: DBI's own array-binding idiom, optimized where it's
# safe to be. Eligible shape (single-tuple "INSERT ... VALUES (?,...)",
# see Placeholders::is_batchable_insert) -> one batched raw-SQL INSERT, one HTTP
# request regardless of tuple count. Anything else -> the same
# per-tuple execute() loop DBI's own default implementation would use;
# never silently skipped or mishandled.
#
# ArrayTupleFetch (row-wise supply via callback/sth) is deliberately
# rejected with a clear error rather than silently ignored -- this
# driver only implements the column-wise bind_param_array/@bind_values
# forms.
#
# ArrayTupleStatus granularity: ClickHouse reports one pass/fail for
# the whole batched statement, not per row. Default: on failure, every
# tuple's status entry gets the same [err, errstr, state] (one HTTP
# request either way). Opt in to per-row diagnosis with
# chng_retry_on_error => 1 (in \%attr, or set beforehand on the
# handle): only on a fast-path failure, retry once, looping execute()
# per tuple so every row gets its own accurate status. Both modes
# always populate a status entry for every tuple -- never left undef.
sub execute_array( $sth, $attr, @bind_values ) {
    return $sth->set_err( $DBI::stderr, 'execute_array requires a hashref as its first argument' )
        unless ref $attr eq 'HASH';
    return $sth->set_err( $DBI::stderr,
        'ArrayTupleFetch is not supported by DBD::ClickhouseNG; use bind_param_array or column-wise @bind_values instead' )
        if $attr->{ArrayTupleFetch};

    if( @bind_values ) {
        for my $i ( 1 .. @bind_values ) {
            $sth->bind_param_array( $i, $bind_values[$i - 1] ) or return undef;
        }
    }

    my $n     = $sth->FETCH( 'NUM_OF_PARAMS' );
    my $bound = $sth->{chng_param_array_bound} // {};
    for my $i ( 1 .. $n ) {
        return $sth->set_err( $DBI::stderr, "bind_param_array not called for parameter $i" )
            unless $bound->{$i};
    }

    my $arrays = $sth->{chng_param_arrays}      // [];
    my $types  = $sth->{chng_param_array_types} // [];

    my $tuple_count = 0;
    my $any_array   = 0;
    for my $i ( 0 .. $n - 1 ) {
        my $v = $arrays->[$i];
        if( ref $v eq 'ARRAY' ) {
            $any_array = 1;
            $tuple_count = @$v if @$v > $tuple_count;
        }
    }
    $tuple_count = 1 if $n == 0 || !$any_array;

    # Every array-bound param must supply exactly one value per tuple; a
    # shorter array would otherwise silently pad missing tuples with
    # undef instead of erroring, per DBI's array-bind convention (only
    # bound scalars broadcast to every tuple).
    for my $i ( 0 .. $n - 1 ) {
        my $v = $arrays->[$i];
        next unless ref $v eq 'ARRAY';
        return $sth->set_err( $DBI::stderr,
            "bind_param_array for parameter @{[ $i + 1 ]} has " . scalar( @$v )
                . " values, expected $tuple_count" )
            unless @$v == $tuple_count;
    }

    $sth->finish;

    if( $tuple_count == 0 ) {
        @{ $attr->{ArrayTupleStatus} } = () if ref $attr->{ArrayTupleStatus} eq 'ARRAY';
        return '0E0';
    }

    my $extract_tuple = sub( $idx ) {
        return [ map {
            my $v = $arrays->[$_];
            ref $v eq 'ARRAY' ? $v->[$idx] : $v;
        } 0 .. $n - 1 ];
    };

    my @tuple_status;
    my $ok;
    if( DBD::ClickhouseNG::Placeholders::is_batchable_insert( $sth->{chng_segments}, $n ) ) {
        my $retry_safe;
        ( $ok, $retry_safe ) = _execute_array_fast_path( $sth, $tuple_count, $arrays, $types, \@tuple_status );
        if( !$ok && $attr->{chng_retry_on_error} && $retry_safe ) {
            @tuple_status = ();
            $ok = _execute_array_looped( $sth, $tuple_count, $extract_tuple, \@tuple_status );
        }
    }
    else {
        $ok = _execute_array_looped( $sth, $tuple_count, $extract_tuple, \@tuple_status );
    }

    @{ $attr->{ArrayTupleStatus} } = @tuple_status if ref $attr->{ArrayTupleStatus} eq 'ARRAY';

    unless( $ok ) {
        # If retry-on-error ran and the *last* attempted tuple happened
        # to succeed, that success would otherwise leave $sth->err
        # cleared -- silently hiding the fact that the batch overall
        # failed (RaiseError/PrintError would never fire, and a caller
        # checking $sth->err after a failed execute_array would
        # wrongly see "no error"). Re-assert a representative failure
        # (the first failing tuple found) so err/errstr/state always
        # reflect the true outcome before returning.
        my( $first_error ) = grep { ref $_ } @tuple_status;
        $sth->set_err( @$first_error ) if $first_error;
    }

    return $ok ? $tuple_count : undef;
}

sub _execute_array_fast_path( $sth, $tuple_count, $arrays, $types, $tuple_status ) {
    my $segments = $sth->{chng_segments};
    my $n        = scalar @$arrays;

    my @tuple_inner;
    for my $idx ( 0 .. $tuple_count - 1 ) {
        my @literals;
        for my $i ( 0 .. $n - 1 ) {
            my $v     = $arrays->[$i];
            my $value = ref $v eq 'ARRAY' ? $v->[$idx] : $v;
            push @literals, DBD::ClickhouseNG::Types::sql_literal( $value, $types->[$i] );
        }
        push @tuple_inner, join( ',', @literals );
    }

    my $sql = $segments->[0] . join( '),(', @tuple_inner ) . $segments->[$n];

    my $res = $sth->{Database}{chng_client}->query( DBD::ClickhouseNG::Error::utf8_bytes( $sql ) );
    unless( $res->{ok} ) {
        DBD::ClickhouseNG::Error::report( $sth, $res, 'execute_array' );
        my $status = [ $sth->err, $sth->errstr, $sth->state ];
        @$tuple_status = ($status) x $tuple_count;
        # A transport failure (599) means the batch's actual effect on
        # the server is unknown -- retrying row-by-row here could
        # silently duplicate data that was already written before the
        # response was lost. Only a definitive server-side rejection
        # is safe to retry (see DESIGN.md's no-retry rationale, §9).
        my $retry_safe = ( ($res->{status} // 0) != 599 );
        return ( 0, $retry_safe );
    }

    @$tuple_status = (-1) x $tuple_count;
    $sth->{chng_rows} = -1;
    return ( 1, 1 );
}

sub _execute_array_looped( $sth, $tuple_count, $extract_tuple, $tuple_status ) {
    my $all_ok = 1;
    for my $idx ( 0 .. $tuple_count - 1 ) {
        my $tuple = $extract_tuple->( $idx );
        my $rv    = $sth->execute( @$tuple );
        if( defined $rv ) {
            push @$tuple_status, $rv;
        }
        else {
            $all_ok = 0;
            push @$tuple_status, [ $sth->err, $sth->errstr, $sth->state ];
        }
    }
    return $all_ok;
}

sub fetch( $sth ) {
    my $data = $sth->{chng_data}
        or return $sth->set_err( $DBI::stderr, 'fetch without successful execute' );

    if( $sth->{chng_pos} >= @$data && $sth->{chng_reader} ) {
        _refill_streaming_batch( $sth );
        $data = $sth->{chng_data};
    }

    if( $sth->{chng_pos} >= @$data ) {
        # finish() (below) is itself a dispatched DBI call, and DBI
        # clears err/errstr at the start of every dispatch -- so any
        # set_err() here, before calling finish(), would be wiped out
        # by finish()'s own dispatch before fetch() ever returns.
        # finish() itself applies any stashed chng_stream_error last,
        # which survives since nothing dispatches after it.
        $sth->finish;
        return undef;
    }
    return $sth->_set_fbav( $data->[ $sth->{chng_pos}++ ] );
}
no warnings 'once';
*fetchrow_arrayref = \&fetch;
use warnings 'once';

sub rows( $sth ) {
    return $sth->{chng_rows} // -1;
}

sub finish( $sth ) {
    if( my $reader = delete $sth->{chng_reader} ) {
        $reader->close;
    }
    $sth->{chng_data} = undef;
    $sth->{chng_pos}  = undef;
    $sth->STORE( Active => 0 );
    $sth->SUPER::finish();

    # Surface (rather than silently drop) a transport error hit
    # mid-batch but not yet reported -- e.g. the caller finishing
    # directly instead of exhausting fetch() (see
    # _refill_streaming_batch's comment on why this can't be reported
    # at the point it happened). Must be the last thing finish() does:
    # DBI clears err/errstr at the start of every dispatched call, so
    # set_err() has to run after STORE/SUPER::finish() above, not
    # before, or those dispatches would wipe it out again.
    if( my $err = delete $sth->{chng_stream_error} ) {
        $sth->set_err( @$err );
    }
    return 1;
}

sub FETCH( $sth, $attrib ) {
    return $sth->{chng_types}     if $attrib eq 'TYPE';
    return $sth->{chng_precision} if $attrib eq 'PRECISION';
    return $sth->{chng_scale}     if $attrib eq 'SCALE';
    return $sth->{chng_nullable}  if $attrib eq 'NULLABLE';
    if( $attrib eq 'ParamValues' ) {
        my $params = $sth->{chng_params} || [];
        return { map { $_ + 1 => $params->[$_] } 0 .. $#$params };
    }
    if( $attrib eq 'ParamTypes' ) {
        my $types = $sth->{chng_param_types} || [];
        return { map { $_ + 1 => $types->[$_] } 0 .. $#$types };
    }
    if( $attrib eq 'ParamArrays' ) {
        my $arrays = $sth->{chng_param_arrays};
        return undef unless $arrays && @$arrays;
        return { map { $_ + 1 => $arrays->[$_] } 0 .. $#$arrays };
    }
    return $sth->{$attrib} if $attrib =~ /\Achng_/;
    return $sth->SUPER::FETCH( $attrib );
}

sub STORE( $sth, $attrib, $value ) {
    return $sth->{NAME} = $value if $attrib eq 'NAME';
    if( $attrib =~ /\Achng_/ ) {
        $sth->{$attrib} = $value;
        return 1;
    }
    return $sth->SUPER::STORE( $attrib, $value );
}
1;
