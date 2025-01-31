use 5.010001;
use strict;
use warnings;

package BSON::OID;
# ABSTRACT: BSON type wrapper for Object IDs

use version;
our $VERSION = 'v1.12.2';

use Carp;
use Config;
use Scalar::Util 'looks_like_number';
use Sys::Hostname;
use threads::shared; # NOP if threads.pm not loaded
use Crypt::URandom ();

use constant {
    HAS_INT64 => $Config{use64bitint},
    INT64_MAX => 9223372036854775807,
    INT32_MAX => 2147483647,
    ZERO_FILL => ("\0" x 8),
};

use Moo;

=attr oid

A 12-byte (packed) Object ID (OID) string.  If not provided, a new OID
will be generated.

=cut

has 'oid' => (
    is => 'ro'
);

use namespace::clean -except => 'meta';

# OID generation
{
    my $_MAX_INC_VALUE = 0xFFFFFF;
    my $_MAX_INC_VALUE_PLUS_ONE = 0x01000000;
    my $_RANDOM_SIZE = 5;
    my $_inc : shared;
    {
        lock($_inc);
        $_inc = int( rand($_MAX_INC_VALUE) );
    }

    # for testing purposes
    sub __reset_counter {
        lock($_inc);
        $_inc = $_MAX_INC_VALUE - 1;
    }

    my $_pid = $$;
    my $_random = Crypt::URandom::urandom($_RANDOM_SIZE);

    sub CLONE { $_random = Crypt::URandom::urandom($_RANDOM_SIZE) }

    #<<<
    sub _packed_oid {
        my $time = defined $_[0] ? $_[0] : time;
        $_random = Crypt::URandom::urandom($_RANDOM_SIZE) if $$ != $_pid;
        return pack(
            'Na5a3',
            $time,
            $_random,
            substr( pack( 'N', do { lock($_inc); $_inc++; $_inc %= $_MAX_INC_VALUE_PLUS_ONE } ), 1, 3)
        );
    }
    sub _packed_oid_special {
        my ($time, $fill) = @_;
        return pack('Na8', $time, $fill);
    }
    #>>>
}

sub BUILD {
    my ($self) = @_;

    $self->{oid} = _packed_oid() unless defined $self->{oid};
    croak "Invalid 'oid' field: OIDs must be 12 bytes"
      unless length( $self->oid ) == 12;
    return;
}

=method new

    my $oid = BSON::OID->new;

    my $oid = BSON::OID->new( oid => $twelve_bytes );

This is the preferred way to generate an OID.  Without arguments, a
unique OID will be generated.  With a 12-byte string, an object can
be created around an existing OID byte-string.

=method from_epoch

    # generate a new OID

    my $oid = BSON::OID->from_epoch( $epoch, 0); # other bytes zeroed
    my $oid = BSON::OID->from_epoch( $epoch, $eight_more_bytes );

    # reset an existing OID

    $oid->from_epoch( $new_epoch, 0 );
    $oid->from_epoch( $new_epoch, $eight_more_bytes );

B<Warning!> You should not rely on this method for a source of unique IDs.
Use this method for query boundaries, only.

An OID is a twelve-byte string.  Typically, the first four bytes represent
integer seconds since the Unix epoch in big-endian format.  The remaining
bytes ensure uniqueness.

With this method, the first argument to this method is an epoch time (in
integer seconds).  The second argument is the remaining eight-bytes to
append to the string.

When called as a class method, it returns a new BSON::OID object.  When
called as an object method, it mutates the existing internal OID value.

As a special case, if the second argument is B<defined> and zero ("0"),
then the remaining bytes will be zeroed.

    my $oid = BSON::OID->from_epoch(1467545180, 0);

This is particularly useful when looking for documents by their insertion
date: you can simply look for OIDs which are greater or lower than the one
generated with this method.

For backwards compatibility with L<Mango>, if called without a second
argument, the method generates the remainder of the fields "like usual".
This is equivalent to calling C<< BSON::OID->new >> and replacing the first
four bytes with the packed epoch value.

    # UNSAFE: don't do this unless you have to

    my $oid = BSON::OID->from_epoch(1467545180);

If you insist on creating a unique OID with C<from_epoch>, set the
remaining eight bytes in a way that guarantees thread-safe uniqueness, such
as from a reliable source of randomness (see L<Crypt::URandom>).

  use Crypt::Random 'urandom';
  my $oid = BSON::OID->from_epoch(1467545180, urandom(8));

=cut

sub from_epoch {
    my ($self, $epoch, $fill) = @_;

    croak "BSON::OID::from_epoch expects an epoch in seconds, not '$epoch'"
      unless looks_like_number( $epoch );

    $fill = ZERO_FILL if defined $fill && looks_like_number($fill) && $fill == 0;

    croak "BSON::OID expects the second argument to be missing, 0 or an 8-byte string"
      unless @_ == 2 || length($fill) == 8;

    my $oid = defined $fill
      ? _packed_oid_special($epoch, $fill)
      : _packed_oid($epoch);

    if (ref $self) {
        $self->{oid} = $oid;
    }
    else {
        $self = $self->new(oid => $oid);
    }

    return $self;
}

=method hex

Returns the C<oid> attributes as 24-byte hexadecimal value

=cut

sub hex {
    my ($self) = @_;
    return defined $self->{_hex}
      ? $self->{_hex}
      : ( $self->{_hex} = unpack( "H*", $self->{oid} ) );
}

=method get_time

Returns a number corresponding to the portion of the C<oid> value that
represents seconds since the epoch.

=cut

sub get_time {
    return unpack( "N", substr( $_[0]->{oid}, 0, 4 ) );
}

=method TO_JSON

Returns a string for this OID, with the OID given as 24 hex digits.

If the C<BSON_EXTJSON> option is true, it will instead be compatible with
MongoDB's L<extended JSON|https://github.com/mongodb/specifications/blob/master/source/extended-json.rst>
format, which represents it as a document as follows:

    {"$oid" : "012345678901234567890123"}

=cut

sub TO_JSON {
    return $_[0]->hex unless $ENV{BSON_EXTJSON};
    return {'$oid' => $_[0]->hex };
}

# For backwards compatibility
*to_string = \&hex;
*value = \&hex;

sub _cmp {
    my ($left, $right, $swap) = @_;
    ($left, $right) = ($right, $left) if $swap;
    return "$left" cmp "$right";
}

# Legacy MongoDB driver tests check for a PID matching $$, but the new OID
# no longer has an embedded PID.  To avoid breaking legacy tests, we make
# this return the masked PID.
sub _get_pid { return $$ & 0xFFFF }

# Legacy BSON::XS tests expect to find a _generate_oid, so we provide
# one for back-compatibility.
sub _generate_oid { _packed_oid() };

use overload (
    '""'     => \&hex,
    "<=>"    => \&_cmp,
    "cmp"    => \&_cmp,
    fallback => 1,
);

1;

__END__

=for Pod::Coverage op_eq to_string value generate_oid BUILD

=head1 SYNOPSIS

    use BSON::Types ':all';

    my $oid  = bson_oid();
    my $oid  = bson_oid->from_epoch(1467543496, 0); # for queries only

    my $bytes = $oid->oid;
    my $hex   = $oid->hex;

=head1 DESCRIPTION

This module provides a wrapper around a BSON L<Object
ID|https://docs.mongodb.com/manual/reference/method/ObjectId/>.

=head1 OVERLOAD

The string operator is overloaded so any string operations will actually use
the 24-character hex value of the OID.  Fallback overloading is enabled.

Both numeric comparison (C<< <=> >>) and string comparison (C<cmp>) are
overloaded to do string comparison of the 24-character hex value of the
OID.  If used with a non-BSON::OID object, be sure to provide a
24-character hex string or the results are undefined.

=head1 THREADS

This module is thread safe.

=cut

# vim: set ts=4 sts=4 sw=4 et tw=75:
