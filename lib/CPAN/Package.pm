package CPAN::Package;

=head1 NAME

CPAN::Package - Build OS packages from CPAN distributions

=head1 SYNOPSIS

    my $conf    = CPAN::Package->new(...);
    my $dist    = $conf->find(Dist => spec => "Scalar::Util");
    my $jail    = $conf->find(Jail => "some-jail");
 
=head1 DESCRIPTION

=head2 Warning

B<This is alpha code. Interfaces may change. May contain sharp edges.>

CPAN::Package is a module for building OS packages from CPAN
distributions. In order to keep the build self-contained, building is
done inside a jail, using a different perl from the one running the
build process.

A CPAN::Package object holds configuration information used for a given
batch of builds. The object has methods to construct other objects used
for the actual building.

=cut

use 5.010;
use warnings;
use strict;
use autodie;

our $VERSION = "2";

use Carp;
use Class::Load     qw/load_class/;
use File::Spec::Functions   qw/devnull/;
use HTTP::Tiny;
use Scalar::Util    qw/blessed/;
use Scope::Guard    qw/guard/;

=head1 ATTRIBUTES

These all have read-only accessors.

=head2 builtby

Your email address. This will be included in the metadata of the build
packages.

=head2 cpan

The base URL of the CPAN mirror to use. Defaults to
F<http://search.cpan.org/CPAN>.

=head2 dist

The directory to use for storing distfiles. This should be an absolute
path.

=head2 extradeps

A hashref of extra dependencies, for distributions which do not properly
declare (in particular) their configure-time deps. This hash is keyed by
distribution name without version (so, C<List-Util>), and should look
like this:

    extradeps => {
        "Authen-SASL-XS" => {
            configure => {
                "Devel::CheckLib" => 0,
            },
        },
    },

that is, the first level key is the distribution name, the second-level
the 'phase' (see L<CPAN::Meta::Prereqs>), and the third a module name
and a CPAN version requirements string.

=head2 metadb

The base URL for the CPAN metadata service. Defaults to
F<http://cpanmetadb.plackperl.org/v1.0/package>. This will have a slash
and a package name appended to it, and should return a YAML document
with a top-level C<distfile> key giving the
F<A/AU/AUTHOR/Dist-File-1.00.tar.gz> path of the distribution containing
that module.

=head2 http

The object to use for making HTTP requests. This should support the same
interface as L<HTTP::Tiny>. Defaults to a new HTTP::Tiny object.

=head2 initpkgs

A list of packages to install immediately after starting the jail. This
is not actually used by CPAN::Package, but is used by L<App::cpan2pkg>.

=head2 msgfh

The filehandle to use for writing messages, controlled by the
C<verbose> setting. Defaults to a dup of C<STDOUT>.

=head2 log

A file to log all messages to, and possibly all build output. This will
only be used if C<logfh> is not provided.

=head2 logfh

A filehandle to write all messages to, regardless of the C<verbose>
setting. If this is not set and C<log> is, the C<log> file will be
opened for writing and overwritten.

=head2 packages

The directory to store the built packages under. A subdirectory will be
created named after the jail, so multiple jails can share a single
package directory.

=head2 perl

The path, within the jail, to the perl to use for building. Defaults to
F</usr/bin/perl>.

=head2 pkgdb

A directory to store the package databases under. These are SQLite files
named after the jails, and they record which distributions have been
built and which modules they provide.

=head2 redirect_stdh

Whether or not to reopen C<STDOUT> and C<STDERR> to the C<logfh>. If
this is not done, any messages printed by the build steps will not be
logged, but since this means manipulating global state the default is
not to do the redirection.

=head2 su

This coderef is invoked whenever a command needs to be run which might
require privilege. The first argument will be the CPAN::Package object;
subsequent arguments will be the command and arguments to be run.
Defaults to simply running the command directly (with C<< $conf->system
>>).

This attribute has no accessor; instead it is invoked with the C<< ->su
>> method.

=head2 verbose

Specifies how verbose the messages emitted on C<msgfh> should be.
C<$level> is an integer from 1 to 4.

=cut

for my $a (qw/ 
    jail perl prefix builtby
    cpan metadb dist packages pkgdb
    http verbose msgfh logfh errfh
/) {
    no strict "refs";
    *$a = sub { $_[0]{$a} };
}

for my $l (qw/ initpkgs /) {
    no strict "refs";
    *$l = sub { @{ $_[0]{$l} } };
}

=head1 METHODS

=head2 new

    my $conf = CPAN::Package->new(%conf);

This constructs a new CPAN::Package object. The arguments should be a
list of attributes.

=cut

sub new {
    my ($class, %conf) = @_;

    $conf{perl}     //= "/usr/bin/perl";
    $conf{cpan}     //= "http://search.cpan.org/CPAN";
    $conf{metadb}   //= "http://cpanmetadb.plackperl.org/v1.0/package";
    $conf{su}       //= sub { $_[0]->system(@_[1..$#_]) };
    $conf{http}     //= HTTP::Tiny->new;
    $conf{verbose}  //= 100;

    $conf{msgfh} or open $conf{msgfh}, ">&", \*STDOUT;
    $conf{errfh} or open $conf{errfh}, ">&", \*STDERR;

    unless ($conf{logfh}) {
        my $log = delete($conf{log}) // devnull;
        open $conf{logfh}, ">", $log;
    }

    if ($conf{redirect_stdh}) {
        open STDOUT, ">&", $conf{logfh};
        open STDERR, ">&", $conf{logfh};
    }

    bless \%conf, $class;
}

=head2 extradeps_for

    my $deps = $conf->extradeps_for("List-Util");

Returns the hashref of extra deps for the given distribution.

=cut

sub extradeps_for { $_[0]{extradeps}{$_[1]} // {} }

=head2 say

=head2 sayf

    $conf->say(1, "Starting build");
    $conf->sayf(2, "Building %s", $build->name);

These methods print messages to C<logfh>, and possibly to C<msgfh>. The
first argument gives the verbosity; if it is C<< >= $conf->verbose >>
the message will go to C<msgfh>.

C<say> takes a list and prints it space-separated. C<sayf> takes a
C<printf> format string and arguments. Both prepend C<< "==>" >>, with
the number of C<=>s depending on the verbosity, and append a newline.

=cut

sub say {
    my ($self, $verb, @what) = @_;

    my $pfx = ("=" x $verb) . "=>";
    local $, = " ";
    say { $self->logfh } $pfx, @what;
    $self->verbose >= $verb and say { $self->msgfh } $pfx, @what;
}

sub sayf {
    my ($self, $verb, $fmt, @args) = @_;

    $self->say($verb, sprintf $fmt, @args);
}

=head2 system

    $conf->system(@cmd);

This is a wrapper around C<system>. Currently it just converts the
return value to true or false, but it may at some point do other things
like redirect C<STDOUT> and C<STDERR>, so you should use this instead of
C<system>.

=cut

sub system {
    my ($self, @cmd) = @_;

    0 == system @cmd;
}

=head2 su

    $conf->su(@cmd);

Invokes the C<su> coderef.

=cut

sub su {
    my ($self, @cmd) = @_;
    $self->{su}->($self, @cmd);
}

=head2 find

    my $object = $conf->find($type, @args);

This is the interface for creating dependent objects. C<$type> is the
type of object to create, for instance C<Jail> or C<Dist>. C<@args> are
the arguments to that type's constructor, omitting the config argument.

=cut

sub find {
    my ($self, $class, @args) = @_;

    load_class("CPAN::Package::$class")->new($self, @args);
}

=head2 resolve_dist

    my $dist = $conf->resolve_dist($spec);

Work out which distribution to build to satisfy C<$spec>. This might be
a module name, or might be something more complicated. This uses L<<
Dist->resolve|CPAN::Package::Dist/resolve >>.

=cut

sub resolve_dist {
    my ($self, $spec) = @_;

    load_class("CPAN::Package::Dist")->resolve($self, $spec);
}

=head2 throw

    $conf->throw(@args);

This creates and throws a L<CPAN::Package::Exception>. C<@args> are
passed to the Exception constructor.

=cut

sub throw {
    my ($self, @args) = @_;

    $self->find(Exception => @args)->throw;
}

1;

=head1 SEE ALSO

L<cpan2pkg> is a command-line interface to this module.

=head1 BUGS

Please report any bugs to L<bug-CPAN-Package@rt.cpan.org>.

=head1 AUTHOR

Copyright 2013 Ben Morrow <ben@morrow.me.uk>.

Released under the 2-clause BSD licence.

