package CPAN::Package::t;

sub new {
    my ($class, @args) = @_;
    return bless \@args, $class;
}

1;
