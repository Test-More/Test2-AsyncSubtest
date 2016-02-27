package Test2::Tools::AsyncSubtest;
use strict;
use warnings;

use Test2::IPC;
use Test2::AsyncSubtest;
use Test2::API qw/context/;
use Carp qw/croak/;

our @EXPORT = qw/async_subtest fork_subtest thread_subtest/;
use base 'Exporter';

sub async_subtest {
    my ($name, $code) = @_;
    my $ctx = context();

    my $subtest = Test2::AsyncSubtest->new(name => $name, context => 1);

    $subtest->run($code, $subtest) if $code;

    $ctx->release;
    return $subtest;
}

sub fork_subtest {
    my ($name, $code) = @_;
    my $ctx = context();

    croak "fork_subtest requires a CODE reference as the second argument"
        unless ref($code) eq 'CODE';

    my $subtest = Test2::AsyncSubtest->new(name => $name, context => 1);

    $subtest->run_fork($code, $subtest);

    $ctx->release;
    return $subtest;
}

sub thread_subtest {
    my ($name, $code) = @_;
    my $ctx = context();

    croak "thread_subtest requires a CODE reference as the second argument"
        unless ref($code) eq 'CODE';

    my $subtest = Test2::AsyncSubtest->new(name => $name, context => 1);

    $subtest->run_thread($code, $subtest);

    $ctx->release;
    return $subtest;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Tools::AsyncSubtest - Tools for writing async subtests.

=head1 DESCRIPTION

These are tools for writing async subtests. Async subtests are subtests which
can be started and stashed so that they can continue to recieve events while
other events are also being generated.

=head1 SYNOPSYS

    use Test2::Bundle::Extended;
    use Test2::Tools::AsyncSubtest;


    done_testing;

=head1 EXPORTS

Everything is exported by default.

=over 4

=item $ast = async_subtest $name

=item $ast = async_subtest $name => sub { ... }


=item $ast = fork_subtest $name => sub { ... }


=item $ast = thread_subtest $name => sub { ... }


=back

=head1 NOTES

=over 4

=item Async Subtests are always buffered.

=back

=head1 SOURCE

The source code repository for Test2-AsyncSubtest can be found at
F<http://github.com/Test-More/Test2-AsyncSubtest/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2015 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
