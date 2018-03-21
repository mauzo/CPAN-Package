#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::NoWarnings ();

for (   "App::cpan2pkg",
        "CPAN::Package",
        map "CPAN::Package::$_", qw/
            Jail
            Base
            Build
            PkgDB
            Exception
            PkgTool
            Dist
            Dist::Git
            Dist::CPAN
        /,
) {
    require_ok $_;
}

Test::More->builder->is_passing
    or BAIL_OUT "Module will not load!";

Test::NoWarnings::had_no_warnings;

done_testing;
