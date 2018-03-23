package CPAN::Package::Exception;

=head1 NAME

CPAN::Package::Exception - Exceptions for CPAN::Package

=head1 SYNOPSIS

    my $ex = CPAN::Package::Exception->new($config, $type, $info);
    $ex->throw;

    $config->throw($type, $info);

=head1 DESCRIPTION

This is the exception class used by L<CPAN::Package>. Exceptions have
C<type> and C<info> fields, where C<type> indicates the source of the
exception and C<info> provides additional information.

=cut

use warnings;
use strict;

use overload 
    q/""/       => sub { $_[0]->_str },
    fallback    => 1;

use Carp ();

use Moo;

extends "CPAN::Package::Base";

=head1 ATTRIBUTES

These have read-only accessors.

=head2 type

The type of exception; see L</EXCEPTION TYPES> below.

=cut

has type    => is => "ro";

=head2 info

Additional information about the exception, as specified for the type.

=cut

has info    => is => "ro";

# private attr
has _str    => is => "ro";

=head1 METHODS

=head2 new

    my $ex = CPAN::Package::Exception->new($config, $type, $info);

This is the constructor. C<$config> is a L<CPAN::Package> object.

Normally one would call L<< CPAN::Package's ->throw
method|CPAN::Package/throw >> to build and throw an exception in one go.

=cut

sub BUILDARGS {
    my ($class, $conf, $type, $info) = @_;
    return {
        config  => $conf,
        type    => $type,
        info    => $info,
        _str    => Carp::shortmess(
            "CPAN::Package::Exception [$type]: $info"),
    };
}

=head2 throw

    $ex->throw;

Throws this exception.

=cut

sub throw { die $_[0] }

1;

=head1 EXCEPTION TYPES

These are the exception types thrown by CPAN::Package. For most types,
C<info> is simply a message; for some, it is structured data. The class
names in brackets are the classes which throw exceptions of this type.

=head2 Build

(L<Build|CPAN::Package::Build>)
An error occurred running a build step.

=head2 Configure

(L<Build|CPAN::Package::Build>)
An error occurred running F<Makefile.PL> or F<Build.PL>.

=head2 Fail

(L<App::cpan2pkg>)
This distribution depends on another which we have already tried and
failed to build.

=head2 Fetch

(L<Dist|CPAN::Package::Dist>)
An error occurred while fetching the distribution's tarball.

=head2 Needed

(L<App::cpan2pkg>)
This is thrown by L<check_reqs|App::cpan2pkg/check_reqs> if there are
modules this distribution requires which we do not yet have packages
for. C<info> is an arrayref listing the modules we need.

=head2 Resolve

(L<Dist|CPAN::Package::Dist>)
We were unable to resolve a module name to a distribution.

=head2 Skip

(L<Build|CPAN::Package::Build>, L<App::cpan2pkg>)
This distribution should be skipped. This might be because
F<Makefile.PL> returned without writing a F<Makefile>, or it might be
because we have already tried it in this build session.

=head2 Unpack

(L<Build|CPAN::Package::Build>)
An error occurred while unpacking the distribution's tarball.

=head1 SEE ALSO

L<CPAN::Package>.

=head1 BUGS

Please report bugs to L<bug-CPAN-Package@rt.cpan.org>.

=head1 AUTHOR

Copyright 2013 Ben Morrow <ben@morrow.me.uk>.

Released under the 2-clause BSD licence.

