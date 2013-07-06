package CPAN::Package::Base;

use 5.010;
use warnings;
use strict;

sub new {
    my ($class, @args) = @_;
    my $self = $class->BUILDARGS(@args);
    bless $self, $class;
    $self->BUILD;
    $self;
}

# all these classes take a CPAN::Package first argument
sub BUILDARGS { 
    my ($class, $config, @args) = @_;
    return { 
        config => $_[1],
        @args,
    };
}

sub BUILD { }

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

for my $d (qw/ say sayf /) {
    no strict "refs";
    *$d = sub {
        my ($self, @args) = @_;
        $self->config->$d(@args);
    };
}

1;
