use Test2::Bundle::Extended -target => 'Test2::AsyncSubtest';
use Test2::AsyncSubtest;
use Test2::Util qw/get_tid CAN_THREAD CAN_REALLY_FORK/;
use Test2::API qw/intercept/;

ok($INC{'Test2/IPC.pm'}, "Loaded Test2::IPC");

# Preserve the API
can_ok($CLASS, qw/name hub trace send_to events finished active stack id children pid tid/);

done_testing;

__END__

my @STACK;

sub init {
    my $self = shift;

    croak "'name' is a required attribute"
        unless $self->{+NAME};

    if (delete $self->{context}) {
        my $ctx = Test2::API::context();
        $self->{+SEND_TO} ||= $ctx->hub;
        $self->{+TRACE}   ||= $ctx->trace;
        $ctx->release;
    }
    else {
        $self->{+SEND_TO} ||= Test2::API::test2_stack()->top;
        $self->{+TRACE}   ||= Test2::Util::Trace->new(frame => [caller(1)]);
    }

    $self->{+STACK} = [@STACK];
    $_->{+_IN_USE}++ for reverse @STACK;

    $self->{+TID}       = get_tid;
    $self->{+PID}       = $$;
    $self->{+ID}        = 1;
    $self->{+FINISHED}  = 0;
    $self->{+ACTIVE}    = 0;
    $self->{+_IN_USE}   = 0;
    $self->{+CHILDREN}  = [];

    unless($self->{+HUB}) {
        my $ipc = Test2::API::test2_ipc();
        my $hub = Test2::AsyncSubtest::Hub->new(format => undef, ipc => $ipc);
        $self->{+HUB} = $hub;
    }

    my $hub = $self->{+HUB};
    $hub->set_ast_ids({});
    my @events;
    $hub->listen(sub { push @events => $_[1] });

    $hub->pre_filter(sub {
        my ($hub, $e) = @_;
        return $e if $hub->is_local;

        my $attached = $self->{+_ATTACHED};
        return $e if $attached && @$attached && $attached->[0] == $$ && $attached->[1] == get_tid;
        $e->trace->throw("You must attach to an AsyncSubtest before you can send events to it from another process or thread");
        return;
    });

    $self->{+EVENTS} = \@events;
}

sub context {
    my $self = shift;
    return Test2::API::Context->new(
        trace => $self->{+TRACE},
        hub   => $self->{+SEND_TO},
    );
}

sub _gen_event {
    my $self = shift;
    my ($type, $id) = @_;

    my $class = "Test2::AsyncSubtest::Event::$type";

    return $class->new(id => $id, trace => Test2::Util::Trace->new(frame => [caller(1)]));
}

sub split {
    my $self = shift;
    my $id = $self->{+ID}++;
    $self->{+HUB}->ast_ids->{$id} = 0;
    return $id;
}

sub attach {
    my $self = shift;
    my ($id) = @_;

    croak "An ID is required" unless $id;

    croak "ID $id is not valid"
        unless defined $self->{+HUB}->ast_ids->{$id};

    croak "ID $id is already attached"
        if $self->{+HUB}->ast_ids->{$id};

    croak "You must attach INSIDE the child process/thread"
        if $self->{+HUB}->is_local;

    $self->{+_ATTACHED} = [ $$, get_tid, $id ];
    $self->{+HUB}->send($self->_gen_event('Attach', $id));
}

sub detach {
    my $self = shift;

    croak "You must detach INSIDE the child process/thread"
        if $self->{+PID} == $$ && $self->{+TID} == get_tid;

    my $att = $self->{+_ATTACHED}
        or croak "Not attached";

    croak "Attempt to detach from wrong child"
        unless $att->[0] == $$ && $att->[1] == get_tid;

    my $id = $att->[2];

    $self->{+HUB}->send($self->_gen_event('Detach', $id));

    delete $self->{+_ATTACHED};
}

sub ready { return !shift->pending }
sub pending {
    my $self = shift;
    my $hub = $self->{+HUB};
    return -1 unless $hub->is_local;

    $hub->cull;

    return $self->{+_IN_USE} + keys %{$self->{+HUB}->ast_ids};
}

sub run {
    my $self = shift;
    my ($code, @args) = @_;

    croak "AsyncSubtest->run() takes a codeblock as the first argument"
        unless $code && ref($code) eq 'CODE';

    $self->start;

    my ($ok, $err, $finished);
    T2_SUBTEST_WRAPPER: {
        $ok = eval { $code->(@args); 1 };
        $err = $@;

        # They might have done 'BEGIN { skip_all => "whatever" }'
        if (!$ok && $err =~ m/Label not found for "last T2_SUBTEST_WRAPPER"/) {
            $ok  = undef;
            $err = undef;
        }
        else {
            $finished = 1;
        }
    }

    $self->stop;

    my $hub = $self->{+HUB};

    if (!$finished) {
        if(my $bailed = $hub->bailed_out) {
            my $ctx = $self->context;
            $ctx->bail($bailed->reason);
            return;
        }
        my $code = $hub->exit_code;
        $ok = !$code;
        $err = "Subtest ended with exit code $code" if $code;
    }

    unless ($ok) {
        my $e = Test2::Event::Exception->new(
            error => $err,
            trace => Test2::Util::Trace->new(frame => [caller(0)]),
        );
        $hub->send($e);
    }

    return $hub->is_passing;
}

sub start {
    my $self = shift;

    croak "Subtest is already complete"
        if $self->{+FINISHED};

    $self->{+ACTIVE}++;

    push @STACK => $self;
    my $hub = $self->{+HUB};
    my $stack = Test2::API::test2_stack();
    $stack->push($hub);
    return $hub->is_passing;
}

sub stop {
    my $self = shift;

    croak "Subtest is not active"
        unless $self->{+ACTIVE}--;

    croak "AsyncSubtest stack mismatch"
        unless @STACK && $self == $STACK[-1];

    pop @STACK;

    my $hub = $self->{+HUB};
    my $stack = Test2::API::test2_stack();
    $stack->pop($hub);
    return $hub->is_passing;
}

sub finish {
    my $self = shift;
    my $hub = $self->hub;

    croak "Subtest is already finished"
        if $self->{+FINISHED}++;

    croak "Subtest can only be finished in the process/thread that created it"
        unless $hub->is_local;

    croak "Subtest is still active"
        if $self->{+ACTIVE};

    $self->wait;

    $hub->finalize($self->trace, 1)
        unless $hub->no_ending || $hub->ended;

    if ($hub->ipc) {
        $hub->ipc->drop_hub($hub->hid);
        $hub->set_ipc(undef);
    }

    my $ctx = $self->context;
    my $e = $ctx->build_event(
        'Subtest',
        pass      => $hub->is_passing,
        name      => $self->{+NAME},
        buffered  => 1,
        subevents => $self->{+EVENTS},
    );

    $ctx->hub->send($e);

    unless ($e->pass) {
        $ctx->failure_diag($e);

        $ctx->diag("Bad subtest plan, expected " . $hub->plan . " but ran " . $hub->count)
            if !$hub->check_plan && !grep {$_->causes_fail} @{$self->{+EVENTS}};
    }

    $_->{+_IN_USE}-- for reverse @{$self->{+STACK}};

    return $e->pass;
}

sub wait {
    my $self = shift;

    my $hub = $self->{+HUB};
    my $children = $self->{+CHILDREN};

    while ($self->pending || @$children) {
        $hub->cull;
        if (my $child = pop @$children) {
            if (blessed($child)) {
                $child->join;
            }
            else {
                waitpid($child, 0);
            }
        }
        else {
            Time::HiRes::sleep('0.01');
        }
    }

    $hub->cull;
}

sub fork {
    croak "Forking is not supported" unless CAN_FORK;
    my $self = shift;
    my $id = $self->split;
    my $pid = CORE::fork();

    unless (defined $pid) {
        delete $self->{+HUB}->ast_ids->{$id};
        croak "Failed to fork";
    }

    if($pid) {
        push @{$self->{+CHILDREN}} => $pid;
        return $pid;
    }

    $self->attach($id);

    return $self->_guard;
}

sub run_fork {
    my $self = shift;
    my ($code, @args) = @_;

    my $f = $self->fork;
    return $f unless blessed($f);

    $self->run($code, @args);

    $self->detach();
    $f->dismiss();
    exit 0;
}

sub run_thread {
    croak "Threading is not supported" unless CAN_THREAD;
    require threads;

    my $self = shift;
    my ($code, @args) = @_;

    my $id = $self->split;
    my $thr =  threads->create(sub {
        $self->attach($id);
        my $guard = $self->_guard();

        $self->run($code, @args);

        $self->detach();
        $guard->dismiss;
        return 0;
    });

    push @{$self->{+CHILDREN}} => $thr;

    return $thr;
}

sub _guard {
    my $self = shift;

    my ($pid, $tid) = ($$, get_tid);

    return Scope::Guard->new(sub {
        return unless $$ == $pid && get_tid == $tid;

        my $error = "Scope Leak";
        if (my $ex = $@) {
            chomp($ex);
            $error .= " ($ex)";
        }

        cluck $error;

        my $e = $self->context->build_event(
            'Exception',
            error => "$error\n",
        );
        $self->{+HUB}->send($e);
        $self->detach();
        exit 255;
    });
}

sub DESTROY {
    my $self = shift;

    if (my $att = $self->{+_ATTACHED}) {
        return unless $self->{+HUB};
        eval { $self->detach() };
    }

    return if $self->{+FINISHED};
    return unless $self->{+PID} == $$;
    return unless $self->{+TID} == get_tid;

    local $@;
    eval { $_->{+_IN_USE}-- for reverse @{$self->{+STACK}} };

    warn "Subtest $self->{+NAME} did not finish!";
    exit 255;
}

1;

__END__
