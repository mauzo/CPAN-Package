package t::CPAN::Package;

use Moo;

use Data::Dump ();
use Test::More;

extends "CPAN::Package";

has t_system => (
    is          => "lazy",
    clearer     => 1,
    init_arg    => undef,
    default     => sub { [] },
);

has t_output => (
    is          => "ro",
    default     => sub { +[] },
);

has t_subst => (
    is          => "rw",
    default     => sub { +{} },
);

sub system {
    my ($self, @cmd) = @_;

    push @{$self->t_system}, \@cmd;

    my $cmd = join " ", @cmd;
    note "SYSTEM $cmd";

    for (@{$self->t_output}) {
        my ($rx, $out) = @$_;
        if ($cmd =~ $rx) {
            if (ref $out) {
                $out->();
            }
            else {
                note "OUTPUT $out";
                print STDOUT $out;
            }
        }
    }

    return 1;
}

sub t_system_is {
    my ($self, $cmds, $name) = @_;

    my $subst = $self->t_subst;
    1 while $cmds =~ s{%(\w+)}{ 
        $$subst{$1} or die "No subst for '$1'";
    }ge;

    my @want = map [split " "], split "\n", $cmds;
    my $got = $self->t_system;

    is_deeply $got, \@want, "correct commands run for $name";

    $self->clear_t_system;
}

1;
