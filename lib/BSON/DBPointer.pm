use 5.010001;
use strict;
use warnings;

package BSON::DBPointer;
# ABSTRACT: Legacy BSON type wrapper for DBPointer data (DEPRECATED)

our $VERSION = 'v1.12.2';

use Moo 2.002004;
use Tie::IxHash;
use namespace::clean -except => 'meta';


extends 'BSON::DBRef';

sub TO_JSON {
    my $self = shift;

    if ( $ENV{BSON_EXTJSON} ) {

        my $id = $self->id;
        if (ref $id) {
            $id = $id->TO_JSON;
        }
        else {
            $id = BSON->perl_to_extjson($id);
        }

        my %data;
        tie( %data, 'Tie::IxHash' );
        $data{'$ref'} = $self->ref;
        $data{'$id'} = $id;
        $data{'$db'} = $self->db
            if defined $self->db;

        my $extra = $self->extra;
        $data{$_} = $extra->{$_}
            for keys %$extra;

        return \%data;
    }

    Carp::croak( "The value '$self' is illegal in JSON" );
}

1;

__END__

=head1 DESCRIPTION

This module wraps the deprecated BSON "DBPointer" type.

You are strongly encouraged to use L<BSON::DBRef> instead.

=cut

# vim: set ts=4 sts=4 sw=4 et tw=75:
