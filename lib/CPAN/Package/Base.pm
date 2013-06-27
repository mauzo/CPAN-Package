package CPAN::Package::Base;

use 5.010;
use warnings;
use strict;

sub new {
    my ($class, %atts) = @_;
    bless \%atts, $class;
}

sub _set {
    my ($self, %atts) = @_;
    while (my ($k, $v) = each %atts) {
        $self->{$k} = $v;
    }
    return $self;
}

sub _new {
    my ($self, $class, @atts) = @_;
    "CPAN::Package::$class"->new(
        config  => $self->config,
        @atts,
    );
}

sub config {
    @_ > 1 and return $_[0]{config}{$_[1]};
    $_[0]{config} //= {};
}

1;
