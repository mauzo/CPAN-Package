package CPAN::Package::HasMeta;

=head1 NAME

CPAN::Package::HasMeta - A role providing CPAN metadata

=head1 SYNOPSIS

    if ($obj->read_meta(...)) {
        my $name = $obj->name;
    }

=head1 DESCRIPTION

This is a role for objects which have CPAN metadata.

=cut

use Moose::Role;

use CPAN::Meta ();

=head1 ATTRIBUTES

=head2 metadata

This is the metadata read from F<{,MY}META.{json,yml}>. Set by
L</read_meta>.

=head2 has_metadata

Returns true if a call to L</read_meta> has read valid metadata, false
otherwise.

=cut

use Sub::Identify;

my $m = __PACKAGE__->can("meta");
warn "META: " . Sub::Identify::sub_fullname($m);

has metadata    => is => "rwp", predicate => 1;

=head1 METHODS

=head2 name

The name of the distribution we are building. Set by L</read_meta>.

=cut

sub name {
    my ($self) = @_;
    my $meta = $self->meta // $self->dist;
    $meta->name;
}

=head2 version

The version of the distribution we are building. Set by L</read_meta>.

=cut

sub version {
    my ($self) = @_;
    my $meta = $self->meta
        or $self->config->throw(Build => "no metadata for version");
    $meta->version;
}

=head2 read_meta

    my $ok = $obj->read_meta($from);

Attempts to read CPAN metadata from C<$from>, and returns true if
successful. The format of C<$from> varies depending on the object; the
base role implementation of the method takes a string, and attempts to
parse it as either JSON or YAML.

=cut

sub read_meta {
    my ($self, $from) = @_;

    my $m = eval { CPAN::Meta->load_json_string($from) }
        || eval { CPAN::Meta->load_yaml_string($from) }
        or return;
    $self->_meta($m);
    return 1;
}

1;

=head1 SEE ALSO

This role is consumed by L<Build|CPAN::Package::Build> and
L<Dist|CPAN::Package::Dist>.

=head1 AUTHOR

Ben Morrow <ben@morrow.me.uk>
