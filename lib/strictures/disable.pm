package strictures::disable;

use warnings;
use strict;

our $VERSION = 1;

$INC{"strictures.pm"} = __FILE__;

no warnings "once";
$strictures::VERSION = $VERSION;

no warnings "redefine";
sub strictures::import {
    strict->import;
    warnings->import;
}

1;
