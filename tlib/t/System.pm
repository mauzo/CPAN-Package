package t::System;

use warnings;
use strict;

use Exporter "import";

our @EXPORT = qw/@System/;

our @System;

*CORE::GLOBAL::system = sub { 
    my ($rv, @args) = @_;
    push @System, \@args;
    return $rv;
};

1;
