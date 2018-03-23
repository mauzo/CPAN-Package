package CPAN::Package::t::Sub;

sub new {
    my ($class, @args) = @_;
    return bless \@args, $class;
}

1;
