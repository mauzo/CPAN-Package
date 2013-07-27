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
use File::Basename      qw/dirname basename/;
use File::Path          qw/make_path/;

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

=item Anything matching C</\.git$/>

A git repo. C<master> will be checked out, unless a different branch or
tag is specified as C<#ref>.

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
        m!\.git(?:#.*)?$!           and $sub = "Git";
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

my $Ext = qr/\.tar(?:\.gz|\.bz2|\.xz)|\.t(?:gz|bz|xz)|\.zip$/;

sub BUILD {
    my ($self) = @_;
    
    my $conf    = $self->config;
    my $dist    = $self->distfile;

    (my $name = basename $dist) =~ s/$Ext//;

    $self->_set(name => $name, tar => "$$conf{dist}/$dist");
}

=head2 make_tar_dir

    my $tar = $dist->make_tar_dir;

Create the directory of C<< $dist->tar >>, and return C<< $dist->tar >>.

=cut

sub make_tar_dir {
    my ($self) = @_;

    my $tar = $self->tar;
    make_path dirname $tar;
    $tar;
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

