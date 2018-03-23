#!/usr/bin/perl

use strict;
use warnings;
use lib "tlib";

use t::All;

my $CP = mk_CPAN_Package;

my $J = $CP->find(Jail => "foo");

is $J->name,            "foo",              "name";
is $J->jname,           "foo-default",      "jname";
is $J->running,         0,                  "running";

$CP->t_subst({
    perl    => "/usr/bin/perl",
    perlver => $PERLVER,
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
