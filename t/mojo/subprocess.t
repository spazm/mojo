use Mojo::Base -strict;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Test::More;

plan skip_all => 'set TEST_SUBPROCESS to enable this test (developer only!)'
  unless $ENV{TEST_SUBPROCESS} || $ENV{TEST_ALL};

use Mojo::IOLoop;
use Mojo::IOLoop::Subprocess;
use Mojo::Promise;
use Mojo::File qw(tempfile);

subtest "Huge result" => sub {
  my ($fail, $result, @start);
  my $subprocess = Mojo::IOLoop::Subprocess->new;
  $subprocess->on(spawn => sub { push @start, shift->pid });
  $subprocess->run(
    sub { shift->pid . $$ . ('x' x 100000) },
    sub {
      my ($subprocess, $err, $two) = @_;
      $fail = $err;
      $result .= $two;
    }
  );
  $result = $$;
  ok !$subprocess->pid, 'no process id available yet';
  is $subprocess->exit_code, undef, 'no exit code';
  Mojo::IOLoop->start;
  ok $subprocess->pid, 'process id available';
  is $subprocess->exit_code, 0, 'zero exit code';
  ok !$fail, 'no error';
  is $result, $$ . 0 . $subprocess->pid . ('x' x 100000), 'right result';
  is_deeply \@start, [$subprocess->pid], 'spawn event has been emitted once';

};

subtest "Custom event loop" => sub {
  my ($fail, $result) = ();
  my $loop = Mojo::IOLoop->new;
  $loop->subprocess(
    sub {'♥'},
    sub {
      my ($subprocess, $err, @results) = @_;
      $fail   = $err;
      $result = \@results;
    }
  );
  $loop->start;
  ok !$fail, 'no error';
  is_deeply $result, ['♥'], 'right structure';

};

subtest "Multiple return values" => sub {
  my ($fail, $result) = ();
  my $subprocess = Mojo::IOLoop::Subprocess->new;
  $subprocess->run(
    sub { return '♥', [{two => 2}], 3 },
    sub {
      my ($subprocess, $err, @results) = @_;
      $fail   = $err;
      $result = \@results;
    }
  );
  Mojo::IOLoop->start;
  ok !$fail, 'no error';
  is_deeply $result, ['♥', [{two => 2}], 3], 'right structure';

};

subtest "Promises" => sub {
  my $result     = [];
  my $subprocess = Mojo::IOLoop::Subprocess->new;
  is $subprocess->exit_code, undef, 'no exit code';
  $subprocess->run_p(sub { return '♥', [{two => 2}], 3 })->then(sub { $result = [@_] })->wait;
  is_deeply $result, ['♥', [{two => 2}], 3], 'right structure';
  my $fail = undef;
  $subprocess = Mojo::IOLoop::Subprocess->new;
  $subprocess->run_p(sub { die 'Whatever' })->catch(sub { $fail = shift })->wait;
  is $subprocess->exit_code, 0, 'zero exit code';
  like $fail, qr/Whatever/, 'right error';
  $result = [];
  Mojo::IOLoop->subprocess->run_p(sub { return '♥' })->then(sub { $result = [@_] })->wait;
  is_deeply $result, ['♥'], 'right structure';

};

subtest "Event loop in subprocess" => sub {
  my ($fail, $result) = ();
  my $subprocess = Mojo::IOLoop::Subprocess->new;
  $subprocess->run(
    sub {
      my $result;
      Mojo::IOLoop->next_tick(sub { $result = 23 });
      Mojo::IOLoop->start;
      return $result;
    },
    sub {
      my ($subprocess, $err, $twenty_three) = @_;
      $fail   = $err;
      $result = $twenty_three;
    }
  );
  Mojo::IOLoop->start;
  ok !$fail, 'no error';
  is $result, 23, 'right result';

};

subtest "Event loop in subprocess (already running event loop)" => sub {
  my ($fail, $result) = ();
  Mojo::IOLoop->next_tick(sub {
    Mojo::IOLoop->subprocess(
      sub {
        my $result;
        my $promise = Mojo::Promise->new;
        $promise->then(sub { $result = shift });
        Mojo::IOLoop->next_tick(sub { $promise->resolve(25) });
        $promise->wait;
        return $result;
      },
      sub {
        my ($subprocess, $err, $twenty_five) = @_;
        $fail   = $err;
        $result = $twenty_five;
      }
    );
  });
  Mojo::IOLoop->start;
  ok !$fail, 'no error';
  is $result, 25, 'right result';

};

subtest "Concurrent subprocesses" => sub {
  my ($fail, $result) = ();
  Mojo::IOLoop->delay(
    sub {
      my $delay = shift;
      Mojo::IOLoop->subprocess(sub {1}, $delay->begin);
      Mojo::IOLoop->subprocess->run(sub {2}, $delay->begin);
    },
    sub {
      my ($delay, $err1, $result1, $err2, $result2) = @_;
      $fail   = $err1 || $err2;
      $result = [$result1, $result2];
    }
  )->wait;
  ok !$fail, 'no error';
  is_deeply $result, [1, 2], 'right structure';

};

subtest "No result" => sub {
  my ($fail, $result) = ();
  Mojo::IOLoop::Subprocess->new->run(
    sub {return},
    sub {
      my ($subprocess, $err, @results) = @_;
      $fail   = $err;
      $result = \@results;
    }
  );
  Mojo::IOLoop->start;
  ok !$fail, 'no error';
  is_deeply $result, [], 'right structure';

};

subtest "Stream inherited from previous subprocesses" => sub {
  my ($fail, $result) = ();
  my $delay = Mojo::IOLoop->delay;
  my $me    = $$;
  for (0 .. 1) {
    my $end        = $delay->begin;
    my $subprocess = Mojo::IOLoop::Subprocess->new;
    $subprocess->run(
      sub { 1 + 1 },
      sub {
        my ($subprocess, $err, $two) = @_;
        $fail ||= $err;
        push @$result, $two;
        is $me, $$, 'we are the parent';
        $end->();
      }
    );
  }
  $delay->wait;
  ok !$fail, 'no error';
  is_deeply $result, [2, 2], 'right structure';

};

subtest "Exception" => sub {
  my $fail = undef;
  Mojo::IOLoop::Subprocess->new->run(
    sub { die 'Whatever' },
    sub {
      my ($subprocess, $err) = @_;
      $fail = $err;
    }
  );
  Mojo::IOLoop->start;
  like $fail, qr/Whatever/, 'right error';

};

subtest "Non-zero exit status" => sub {
  my $fail       = undef;
  my $subprocess = Mojo::IOLoop::Subprocess->new;
  $subprocess->run(
    sub { exit 3 },
    sub {
      my ($subprocess, $err) = @_;
      $fail = $err;
    }
  );
  Mojo::IOLoop->start;
  is $subprocess->exit_code, 3, 'right exit code';
  like $fail, qr/offset 0/, 'right error';

};

subtest "Serialization error" => sub {
  my $fail       = undef;
  my $subprocess = Mojo::IOLoop::Subprocess->new;
  $subprocess->deserialize(sub { die 'Whatever' });
  $subprocess->run(
    sub { 1 + 1 },
    sub {
      my ($subprocess, $err) = @_;
      $fail = $err;
    }
  );
  Mojo::IOLoop->start;
  like $fail, qr/Whatever/, 'right error';

};

subtest "Progress" => sub {
  my ($fail, $result) = (undef, undef);
  my @progress;
  my $subprocess = Mojo::IOLoop::Subprocess->new;
  $subprocess->run(
    sub {
      my $s = shift;
      $s->progress(20);
      $s->progress({percentage => 45});
      $s->progress({percentage => 90}, {long_data => [1 .. 1e5]});
      'yay';
    },
    sub {
      my ($subprocess, $err, @res) = @_;
      $fail   = $err;
      $result = \@res;
    }
  );
  $subprocess->on(
    progress => sub {
      my ($subprocess, @args) = @_;
      push @progress, \@args;
    }
  );
  Mojo::IOLoop->start;
  ok !$fail, 'no error';
  is_deeply $result, ['yay'], 'correct result';
  is_deeply \@progress, [[20], [{percentage => 45}], [{percentage => 90}, {long_data => [1 .. 1e5]}]],
    'correct progress';

};

subtest "Cleanup" => sub {
  my ($fail, $result) = ();
  my $file       = tempfile;
  my $called     = 0;
  my $subprocess = Mojo::IOLoop::Subprocess->new;
  $subprocess->on(cleanup => sub { $file->spurt(shift->serialize->({test => ++$called})) });
  $subprocess->run(
    sub {'Hello Mojo!'},
    sub {
      my ($subprocess, $err, $hello) = @_;
      $fail   = $err;
      $result = $hello;
    }
  );
  Mojo::IOLoop->start;
  is_deeply $subprocess->deserialize->($file->slurp), {test => 1}, 'cleanup event emitted once';
  ok !$fail, 'no error';
  is $result, 'Hello Mojo!', 'right result';
};

done_testing();
