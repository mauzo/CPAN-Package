package CPAN::Package::Base;

use 5.010;
use warnings;
use strict;

sub new {
    my ($class, %atts) = @_;
    bless \%atts, $class;
}

sub _set {
    my ($self, @atts) = @_;
    while (my ($k, $v) = splice @atts, 0, 2) {
        $self->{$k} = $v;
    }
    return $self;
}

sub config {
    my ($self, $key) = @_;
    my $config = $$self{config};
    defined $key or return $config;
    $config->$key;
}

1;
