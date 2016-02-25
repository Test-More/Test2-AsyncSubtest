package Test2::AsyncSubtest::Event::Detach;
use strict;
use warnings;

use base 'Test2::Event';
use Test2::Util::HashBase qw/id/;

sub callback {
    my $self = shift;
    my ($hub) = @_;

    my $id = $self->{+ID};
    my $ids = $hub->ast_ids;

    unless (defined $ids->{$id}) {
        require Test2::Event::Exception;
        my $trace = $self->trace;
        $hub->send(
            Test2::Event::Exception->new(
                trace => $trace,
                error => "Invalid AsyncSubtest detach ID: $id at " . $trace->debug . "\n",
            )
        );
        return;
    }

    unless (delete $ids->{$id}) {
        require Test2::Event::Exception;
        my $trace = $self->trace;
        $hub->send(
            Test2::Event::Exception->new(
                trace => $trace,
                error => "AsyncSubtest ID $id is not attached at " . $trace->debug . "\n",
            )
        );
        return;
    }
}

1;
