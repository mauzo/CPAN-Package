package CPAN::Package::Base;

=head1 NAME

CPAN::Package::Base - Base class for CPAN::Package classes

=head1 SYNOPSIS

    use Moo;
    extends "CPAN::Package::Base";

    sub BUILD {...}

=head1 DESCRIPTION

This is the base class for CPAN::Package classes.

=cut

use 5.010;
use warnings;
use strict;

use Moo;

has _config => (
   is       => "ro",
   init_arg => "config",
   handles  => [qw/say sayf warn warnf/],
);

=head1 METHODS

=head2 new

    $class->new($config, @args);

C<new> is the constructor. It is created by L<Moo>, so it calls
C<BUILDARGS> to convert its arguments into a hashref of attributes, then
calls C<BUILD> after the object has been constructed.

=head2 BUILDARGS

C<BUILDARGS> is called by C<new>, and is expected to turn the argument
list to C<new> into a hashref of attributes. All C<CPAN::Package>
classes are expected to take a C<CPAN::Package> object as the first
argument, and use it to set the C<config> attribute.

=cut

# all these classes take a CPAN::Package first argument
sub BUILDARGS { 
    my ($class, $config, @args) = @_;
    return { 
        config => $config,
        @args,
    };
}

=head2 _set

    $obj->_set(attr => $value);

Objects should use C<_set> to set attributes, rather than accessing the
internal hashref directly. C<_set> returns the object it was called on,
for chaining.

=cut

sub _set {
    my ($self, @atts) = @_;
    while (my ($k, $v) = splice @atts, 0, 2) {
        my $s = "_set_$k";
        $self->$s($v);
    }
    return $self;
}

=head2 config

    my $conf    = $obj->config;
    my $value   = $obj->config("key");

If called with no arguments, returns the C<config> attribute. If called
with a single argument, returns that attribute of the C<config>.

=cut

sub config {
    my ($self, $key) = @_;
    my $config = $self->_config;
    defined $key or return $config;
    $config->$key;
}

=head2 say

=head2 sayf

=head2 warn

=head2 warnf

These pass through to C<config>.

=cut

1;

=head1 SEE ALSO

L<CPAN::Package>

=head1 BUGS

Please report bugs to L<bug-CPAN-Package@rt.cpan.org>.

=head1 AUTHOR

Copyright 2013 Ben Morrow <ben@morrow.me.uk>.

Released under the 2-clause BSD licence.
