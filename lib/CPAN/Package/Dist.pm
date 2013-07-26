package CPAN::Package::Dist;

=head1 NAME

CPAN::Package::Dist - A CPAN distribution

=head1 SYNOPSIS

    my $dist = $config->find(Dist => spec => "Scalar::Util");
    say for $dist->fullname, $dist->distfile;

    $dist->fetch;
    say $dist->tar;

=head1 DESCRIPTION

A Dist object represents a single CPAN distribution.

=cut

use 5.010;
use warnings;
use strict;
use autodie;

use parent "CPAN::Package::Base";

use Encode              qw/decode/;
use File::Basename      qw/dirname/;
use File::Path          qw/make_path/;
use Parse::CPAN::Meta;

my $Ext = qr/\.tar(?:\.gz|\.bz2|\.xz)|\.t(?:gz|bz|xz)|\.zip$/;

=head1 ATTRIBUTES

These have read-only accessors, though some are set by other methods.

=head2 name

The name of the distribution, without version.

=head2 version

The version of the distribution.

=head2 distfile

The path to the distribution's tarball, relative to a CPAN mirror. Set
by L</resolve>.

=head2 tar

The local (host) path to the downloaded tarball. Set by L</fetch>.

=cut

for my $m (qw/name version distfile tar/) {
    no strict "refs";
    *$m = sub { $_[0]{$m} };
}

=head1 METHODS

=head2 resolve

    my %atts = CPAN::Package::Dist->resolve($config, $spec);

This is a class method called by L</new>. It resolves a module name to a
distribution, using the C<metadb> from C<$config>.

=cut

sub resolve {
    my ($class, $conf, $spec) = @_;

    $conf->say(1, "Resolving $spec");

    my $distfile;
    if ($spec =~ m!^([A-Z])([A-Z])([A-Z]+)/(.*)!) {
        $distfile = "$1/$1$2/$1$2$3/$4";
    }
    else {
        my $rs = $conf->http->get("$$conf{metadb}/$spec");
        $$rs{success} or $conf->throw(Resolve =>
            "can't resolve module '$spec'");
        
        my $meta = Parse::CPAN::Meta->load_yaml_string(
            decode "utf8", $$rs{content}
        ) or $conf->throw(Resolve => "can't parse meta for '$spec'");
        $distfile = $$meta{distfile};
    }

    my ($name, $version) = $distfile =~
            m!^ .*/ ([-A-Za-z0-9_+]+) - ([^-]+) $Ext $!x
        or $conf->throw(Resolve =>
            "Can't parse distfile name '$distfile'");

    $conf->say(3, "Resolved $spec to $distfile");
    
    return {
        config      => $conf,
        name        => $name,
        version     => $version,
        distfile    => $distfile,
    };
}

=head2 new

    my $dist = CPAN::Package::Dist->new($config, 
        spec => "Scalar::Util");
    my $dist = CPAN::Package::Dist->new($config,
        name    => "List-Util",
        version => "1.0",
    );

This is the constructor. If you pass a single C<spec> argument, this
should be a module name. It will be resolved with L</resolve> and
C<name>, C<version> and C<distfile> set from the results. Alternatively,
if you pass C<name> and C<version> arguments, C<distfile> will remain
unset, so the dist will not be fetchable.

=cut

sub BUILDARGS {
    my ($class, $conf, %args) = @_;

    if (my $spec = $args{spec}) {
        return $class->resolve($conf, $spec);
    }

    return {
        %args,
        config  => $conf,
    };
}

=head2 fullname

The full name of the distribution, in the form F<List-Util-1.0>.

=cut

sub fullname { join "-", map $_[0]->$_, qw/name version/ }

=head2 fetch

    $dist->fetch;

This fetches the dist tarball, using the C<cpan> and C<dist> entries in
the config. If C<distfile> is not set or the fetch fails, throws a
C<Fetch> L<exception|CPAN::Package::Exception>.

=cut

sub fetch {
    my ($self) = @_;

    my $conf    = $self->config;
    my $dist    = $self->distfile
        or $conf->throw(Fetch => "distfile is not set");

    my $path    = "$$conf{dist}/$dist";
    my $url     = "$$conf{cpan}/authors/id/$dist";

    $self->say(1, "Fetching $dist");

    make_path dirname $path;

    my $rs = $conf->http->mirror($url, $path);
    $$rs{success} or $conf->throw(Fetch =>
        "Fetch for $dist failed: $$rs{reason}");
    $$rs{status} == 304 and $self->say(2, "Already fetched");

    $self->_set(tar => $path);
    return $path;
}

1;

=head1 SEE ALSO

L<CPAN::Package>, L<CPAN::Package::Build>.

=head1 BUGS

Please report bugs to L<bug-CPAN-Package@rt.cpan.org>.

=head1 AUTHOR

Copyright 2013 Ben Morrow <ben@morrow.me.uk>.

Released under the 2-clause BSD licence.

