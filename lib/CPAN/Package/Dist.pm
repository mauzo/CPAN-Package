package CPAN::Package::Dist;

=head1 NAME

CPAN::Package::Dist - A CPAN distribution

=head1 SYNOPSIS

    my $dist = CPAN::Package::Dist->resolve($config, "List::Util");
    say for $dist->name, $dist->distfile;

    $dist->fetch;
    say $dist->tar;

=head1 DESCRIPTION

A Dist object represents a single CPAN-like distribution. Subclasses of
Dist represent different sources of distributions: CPAN itself, dists
kept in VCS, and so on.

=cut

use 5.010;
use warnings;
use strict;
use autodie;

use parent "CPAN::Package::Base";

use Class::Load         qw/load_class/;
use Encode              qw/decode/;
use File::Basename      qw/dirname/;
use File::Path          qw/make_path/;
use Parse::CPAN::Meta;

my $Ext = qr/\.tar(?:\.gz|\.bz2|\.xz)|\.t(?:gz|bz|xz)|\.zip$/;

=head1 ATTRIBUTES

These have read-only accessors, though some are set by other methods.

=head2 name

A suitable name to give this distribution. It may not be the same as the
distribution name inside the F<META.json> file, since we can't read that
until the dist has been unpacked.

=head2 distfile

The path to the distribution's tarball, relative to a CPAN mirror. For
non-CPAN distributions this will be under the C<L/LO/LOCAL> directory.
Set by L</resolve>.

=head2 tar

The local (host) path to the downloaded tarball.

=cut

for my $m (qw/name distfile tar/) {
    no strict "refs";
    *$m = sub { $_[0]{$m} };
}

=head1 METHODS

=head2 resolve

    my $dist = CPAN::Package::Dist->resolve($config, $spec);

This is a class method, and the usual constructor. It resolves a module
specification to a dist, which will be in an appropriate subclass.
C<$spec> is a string in one of the following formats:

=over 4

=item F<A/AU/AUTHOR/Some-Dist-1.0.tar.gz>

=item F<AUTHOR/Some-Dist-1.0.tar.gz>

The full path to a (real) CPAN distribution.

=item F<Some::Module>

A module on CPAN. This will be looked up using the config's C<metadb>.

=back

Subclasses are expected to implement this method to resolve their own
specific formats.

=cut

sub resolve {
    my ($class, $conf, $spec) = @_;

    $conf->say(1, "Resolving $spec");

    my $sub;
    for ($spec) {
        my $A = qr/[A-Z]/;

        m!^(?:$A/$A$A/)?$A+/!       and $sub = "CPAN";
        m!^[\w:]+$!                 and $sub = "CPAN";
    }
    $sub or $conf->throw(Resolve => "can't resolve '$spec'");

    my $dist = load_class("$class\::$sub")
        ->resolve($conf, $spec);

    $conf->sayf(2, "Resolved to %s", $dist->distfile);
    $dist;
}

=head2 new

    my $dist = CPAN::Package::Dist->new($config, %attrs);

This is the constructor. The hashref of attributes is usually created by
the L</resolve> method.

=cut

sub BUILD {
    my ($self) = @_;
    
    my $conf    = $self->config;
    my $dist    = $self->distfile;

    my ($name)  = $dist =~
            m!^ .*/ ([-A-Za-z0-9_+]+?) (?: - [0-9._]+ )? $Ext $!x
        or $conf->throw(Resolve =>
            "Can't parse distfile name '$dist'");

    $self->_set(name => $name, tar => "$$conf{dist}/$dist");
}

=head2 fetch

    $dist->fetch;

This fetches the dist tarball, using the C<cpan> and C<dist> entries in
the config. If C<distfile> is not set or the fetch fails, throws a
C<Fetch> L<exception|CPAN::Package::Exception>.

=cut

sub fetch { ... }

1;

=head1 SEE ALSO

L<CPAN::Package>, L<CPAN::Package::Build>.

=head1 BUGS

Please report bugs to L<bug-CPAN-Package@rt.cpan.org>.

=head1 AUTHOR

Copyright 2013 Ben Morrow <ben@morrow.me.uk>.

Released under the 2-clause BSD licence.

