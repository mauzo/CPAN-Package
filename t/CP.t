#!/usr/bin/perl

use 5.012;
use warnings;
use lib "tlib";

use Test::More;
use t::System;

use CPAN::Package;
use Try::Tiny;
use Data::Dump      qw/pp/;

open my $LOGH, ">>", \my $logh;
open my $MSGH, ">>", \my $msgh;

{
    my $C = CPAN::Package->new(
        builtby     => "ben\@morrow.me.uk",
        config      => {
            one     => "two",
            three   => {
                four    => "five",
            },
        },
        dist        => "/top/dist",
        extradeps   => {
            "Foo-Bar" => {
                configure => {
                    "Bar::Baz" => 1,
                },
            },
        },
        msgfh       => $MSGH,
        logfh       => $LOGH,
        packages    => "/top/pkg",
        pkgdb       => "/top/pkgdb",
        verbose     => 2,
    );

    is $C->builtby,         "ben\@morrow.me.uk",        "builtby";
    is $C->dist,            "/top/dist",                "dist";
    is $C->packages,        "/top/pkg",                 "packages";
    is $C->pkgdb,           "/top/pkgdb",               "pkgdb";

    is $C->config("one"),   "two",                      "config, one";
    is $C->config("three", "four"),
                            "five",                     "config, two";
    ok !defined($C->config("six")),                     "config, not there";

    is_deeply $C->extradeps_for("Foo-Bar"),
        { configure => { "Bar::Baz" => 1 } },           "extradeps";
    is_deeply $C->extradeps_for("Not-There"), {},       "extradeps, not there";

    is $C->cpan,            "http://search.cpan.org/CPAN",      "cpan";
    is $C->metadb,          "http://cpanmetadb.plackperl.org/v1.0/package",
                                                                "metadb";
    isa_ok $C->http,        "HTTP::Tiny",               "http";
    is $C->perl,            "/usr/bin/perl",            "perl";

    ($logh, $msgh) = ("X", "Y");
    $C->say(1, "foo", "bar");
    is $logh,               "X==> foo bar\n",           "logh, say, 1";
    is $msgh,               "Y==> foo bar\n",           "msgh, say, 1";

    ($logh, $msgh) = ("X", "Y");
    $C->sayf(1, "foo %s %i", "bar", 3);
    is $logh,               "X==> foo bar 3\n",         "logh, sayf, 1";
    is $msgh,               "Y==> foo bar 3\n",         "msgh, sayf, 1";

    ($logh, $msgh) = ("X", "Y");
    $C->say(2, "foo", "bar");
    is $logh,               "X===> foo bar\n",          "logh, say, 2";
    is $msgh,               "Y===> foo bar\n",          "msgh, say, 2";

    ($logh, $msgh) = ("X", "Y");
    $C->sayf(2, "foo %s %i", "bar", 3);
    is $logh,               "X===> foo bar 3\n",        "logh, sayf, 2";
    is $msgh,               "Y===> foo bar 3\n",        "msgh, sayf, 2";

    ($logh, $msgh) = ("X", "Y");
    $C->say(3, "foo", "bar");
    is $logh,               "X====> foo bar\n",         "logh, say, 3";
    is $msgh,               "Y",                        "msgh, say, 3";

    ($logh, $msgh) = ("X", "Y");
    $C->sayf(3, "foo %s %i", "bar", 3);
    is $logh,               "X====> foo bar 3\n",       "logh, sayf, 3";
    is $msgh,               "Y",                        "msgh, sayf, 3";

    ($logh, $msgh) = ("X", "Y");
    $C->warn("foo");
    is $logh,               "X!!! foo\n",               "logh, warn";
    is $msgh,               "Y!!! foo\n",               "msgh, warn";

    ($logh, $msgh) = ("X", "Y");
    $C->warnf("foo %s %i", "bar", 2);
    is $logh,               "X!!! foo bar 2\n",         "logh, warnf";
    is $msgh,               "Y!!! foo bar 2\n",         "msgh, warnf";

    @System = ();
    ok $C->system(0, "foo"),                            "system, exit 0";
    is_deeply \@System, [["foo"]],                      "system, args";

    ok !$C->system(1, "foo"),                           "system, exit 1";
    ok !$C->system(255, "foo"),                         "system, exit 255";

    @System = ();
    ok $C->su(0, "foo"),                                "su, exit 0";
    is_deeply \@System, [["foo"]],                      "su, args";

    my $o = $C->find("t::Sub", "foo");
    isa_ok $o,              "CPAN::Package::t::Sub",    "find";
    ok exists $INC{"CPAN/Package/t/Sub.pm"},            "find, load";
    is $o->[0],             $C,                         "find, config";
    is $o->[1],             "foo",                      "find, args";

    my @Resolve;
    package CPAN::Package::Dist {
        $INC{"CPAN/Package/Dist.pm"} = __FILE__;
        sub resolve { 
            push @Resolve, \@_;
            return 24;
        }
    }

    my $d = $C->resolve_dist("Foo::Bar");
    is_deeply \@Resolve, 
        [["CPAN::Package::Dist", $C, "Foo::Bar"]],      "resolve_dist, args";
    is $d,              24,                             "resolve_dist, rv";

    my $caught;
    try {
        $C->throw(Skip => "foo");
    }
    catch {
        $caught = $_;
    };

    isa_ok $caught,     "CPAN::Package::Exception",     "throw";
    is $caught->type,   "Skip",                         "throw, type";
    is $caught->info,   "foo",                          "throw, info";
}

done_testing;
