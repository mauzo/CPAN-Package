#!/usr/bin/perl

use strict;
use warnings;
use lib "tlib";

use Test::More;

use t::CPAN::Package;

use Cwd         qw/abs_path/;
use Data::Dump  qw/pp/;
use File::Path  qw/make_path remove_tree/;
use File::Slurp qw/read_file/;

my $TMP = abs_path "ttmp";

sub setup_ttmp {
    remove_tree $TMP;
    make_path map "$TMP/$_", qw(
        pkg pkgdb jail/cpan2pkg/pkg jail/cpan2pkg/repos
    );
}

my $MY = "$TMP/jail/cpan2pkg";

my $perlver = ($^V =~ s/^v//r);
my %perlV = (
    version         => ($^V =~ s/^v//r),
    installbin      => "/usr/local/bin",
    installsitebin  => "/usr/local/bin",
);

my $CP = t::CPAN::Package->new(
    packages    => "$TMP/pkg",
    pkgdb       => "$TMP/pkgdb",
    su          => sub { $_[0]->system("SU", @_[1..$#_]) },
    t_output    => [
        [qr/^jls .* path$/,             "$TMP/jail\n"               ],
        [qr!/corelist !,                "Foo 1.01\nBar 2.02\n"      ],
        map [qr!/perl .*(?<= )-V:$_\b!, "$_='$perlV{$_}';\n"        ],
            keys %perlV,
    ],
) or die "Can't build t::CPAN::Package";

my $J = $CP->find(Jail => "foo");

is $J->name,            "foo",              "name";
is $J->jname,           "foo-default",      "jname";
is $J->running,         0,                  "running";

$CP->t_subst({
    perl    => "/usr/bin/perl",
    perlver => $perlver,
    top     => $TMP,
    my      => $MY,
    jname   => $J->jname,
    injail  => "SU jexec %jname /bin/sh /cpan2pkg/injail",
});

setup_ttmp;
$J->start;

$CP->t_system_is(<<CMD,                     "jail start");
SU poudriere jail -s -j foo
jls -j %jname path
SU mkdir -p %my/
SU mount -t tmpfs -o mode=777 tmpfs %my/
SU mkdir -p %top/pkg/%jname %my/pkg
SU mount -t nullfs -w %top/pkg/%jname %my/pkg
%injail /cpan2pkg/. tar -xvf /packages/Latest/pkg.txz -s,/.*/,, */pkg-static
CMD

is $J->running,         1,                              "running after start";

is $J->jpath("foo"),    "/cpan2pkg/foo",                "jpath";
is $J->hpath("foo"),    "$MY/foo",                      "hpath";

my $pkg = $J->pkgtool;

isa_ok $pkg,            "CPAN::Package::PkgTool",       "pkgtool";
is $pkg->jail,          $J,                             "pkgtool->jail";

my $db = $J->pkgdb;

$CP->t_system_is(<<CMD,                                 "pkgdb");
%injail /cpan2pkg/ %perl -V:version -V:installbin
%injail /cpan2pkg/. /usr/local/bin/corelist -v %perlver /./
CMD

isa_ok $db,             "CPAN::Package::PkgDB",         "pkgdb";
is $db->jail,           $J,                             "pkgdb->jail";

ok -d "$MY/build",                      "build dir exists";
ok -f "$MY/injail",                     "injail exists";

my $injail = read_file "$MY/injail";
like $injail,           $_,             "injail contents"
    for qr/LC_ALL=C/, qr/TZ=UTC/, qr/PERL5_CPAN_IS_RUNNING=/a;

is_deeply [$J->umount], ["pkg", ""],    "umount";

$J->injail("foo", "bar", "baz");

$CP->t_system_is(<<CMD,                 "injail");
%injail /cpan2pkg/foo bar baz
CMD

$J->stop;

$CP->t_system_is(<<CMD,                 "stop");
SU umount %my/pkg
SU umount %my/
SU poudriere jail -k -j foo
CMD

is $J->running,         0,              "running after stop";

setup_ttmp;
$J->start;
$CP->clear_t_system;

undef $J;

$CP->t_system_is(<<CMD,                 "stopped on DESTROY");
SU umount %my/pkg
SU umount %my/
SU poudriere jail -k -j foo
CMD

done_testing;
