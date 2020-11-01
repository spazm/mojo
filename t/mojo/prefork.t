use Mojo::Base -strict;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Test::More;

plan skip_all => 'set TEST_PREFORK to enable this test (developer only!)' unless $ENV{TEST_PREFORK} || $ENV{TEST_ALL};

use Mojo::File qw(curfile path tempdir);
use Mojo::IOLoop::Server;
use Mojo::Server::Prefork;
use Mojo::UserAgent;

my $dir  = tempdir;
my $file = $dir->child('prefork.pid');

subtest "Manage and clean up PID file" => sub {
  my $prefork = Mojo::Server::Prefork->new;
  ok $prefork->pid_file, 'has default path';

  $prefork->pid_file($file);
  ok !$prefork->check_pid, 'no process id';

  $prefork->ensure_pid_file(-23);
  ok -e $file, 'file exists';

  is path($file)->slurp, "-23\n", 'right process id';
  ok !$prefork->check_pid, 'no process id';
  ok !-e $file, 'file has been cleaned up';

  $prefork->ensure_pid_file($$);
  ok -e $file, 'file exists';
  is path($file)->slurp, "$$\n", 'right process id';
  is $prefork->check_pid, $$, 'right process id';

  undef $prefork;
  ok !-e $file, 'file has been cleaned up';
};

subtest "Bad PID file" => sub {
  my $bad     = curfile->sibling('does_not_exist', 'test.pid');
  my $prefork = Mojo::Server::Prefork->new(pid_file => $bad);
  $prefork->app->log->level('debug')->unsubscribe('message');
  my $log = '';
  my $cb  = $prefork->app->log->on(message => sub { $log .= pop });
  eval { $prefork->ensure_pid_file($$) };
  like $@,     qr/Can't create process id file/, 'right error';
  unlike $log, qr/Creating process id file/,     'right message';
  like $log,   qr/Can't create process id file/, 'right message';

  $prefork->app->log->unsubscribe(message => $cb);
};

subtest "Multiple workers and graceful shutdown" => sub {
  my $port    = Mojo::IOLoop::Server::->generate_port;
  my $prefork = Mojo::Server::Prefork->new(heartbeat_interval => 0.5, listen => ["http://*:$port"], pid_file => $file);
  $prefork->unsubscribe('request');
  $prefork->on(
    request => sub {
      my ($prefork, $tx) = @_;
      $tx->res->code(200)->body('just works!');
      $tx->resume;
    }
  );
  is $prefork->workers, 4, 'start with four workers';

  my (@spawn, @reap, $worker, $tx, $graceful);
  $prefork->on(spawn => sub { push @spawn, pop });
  $prefork->on(
    heartbeat => sub {
      my ($prefork, $pid) = @_;
      $worker = $pid;
      return if $prefork->healthy < 4;
      $tx = Mojo::UserAgent->new->get("http://127.0.0.1:$port");
      kill 'QUIT', $$;
    }
  );
  $prefork->on(reap   => sub { push @reap, pop });
  $prefork->on(finish => sub { $graceful = pop });
  $prefork->app->log->level('debug')->unsubscribe('message');
  my $log = '';
  my $cb  = $prefork->app->log->on(message => sub { $log .= pop });
  is $prefork->healthy, 0, 'no healthy workers';

  my @server;
  $prefork->app->hook(
    before_server_start => sub {
      my ($server, $app) = @_;
      push @server, $server->workers, $app->mode;
    }
  );
  $prefork->run;
  is_deeply \@server, [4, 'development'], 'hook has been emitted once';
  is scalar @spawn, 4, 'four workers spawned';
  is scalar @reap,  4, 'four workers reaped';
  ok !!grep { $worker eq $_ } @spawn, 'worker has a heartbeat';
  ok $graceful, 'server has been stopped gracefully';
  is_deeply [sort @spawn], [sort @reap], 'same process ids';
  is $tx->res->code, 200,           'right status';
  is $tx->res->body, 'just works!', 'right content';
  like $log, qr/Listening at/,                                         'right message';
  like $log, qr/Manager $$ started/,                                   'right message';
  like $log, qr/Creating process id file/,                             'right message';
  like $log, qr/Stopping worker $spawn[0] gracefully \(120 seconds\)/, 'right message';
  like $log, qr/Worker $spawn[0] stopped/,                             'right message';
  like $log, qr/Manager $$ stopped/,                                   'right message';

  $prefork->app->log->unsubscribe(message => $cb);

  # Process id file
  is $prefork->check_pid, $$, 'right process id';

  my $pid = $prefork->pid_file;
  ok -e $pid, 'process id file has been created';

  undef $prefork;
  ok !-e $pid, 'process id file has been removed';
};

subtest "One worker and immediate shutdown" => sub {
  my $port = Mojo::IOLoop::Server->generate_port;
  my $prefork
    = Mojo::Server::Prefork->new(accepts => 500, heartbeat_interval => 0.5, listen => ["http://*:$port"], workers => 1);
  $prefork->unsubscribe('request');
  $prefork->on(
    request => sub {
      my ($prefork, $tx) = @_;
      $tx->res->code(200)->body('works too!');
      $tx->resume;
    }
  );
  my (@spawn, @reap, $tx, $graceful);
  my $count = $tx = $graceful = undef;
  @spawn = @reap = ();
  $prefork->on(spawn => sub { push @spawn, pop });
  $prefork->once(
    heartbeat => sub {
      $tx = Mojo::UserAgent->new->get("http://127.0.0.1:$port");
      kill 'TERM', $$;
    }
  );
  $prefork->on(reap   => sub { push @reap, pop });
  $prefork->on(finish => sub { $graceful = pop });
  $prefork->run;
  is $prefork->ioloop->max_accepts, 500, 'right value';
  is scalar @spawn, 1, 'one worker spawned';
  is scalar @reap,  1, 'one worker reaped';
  ok !$graceful, 'server has been stopped immediately';
  is $tx->res->code, 200,          'right status';
  is $tx->res->body, 'works too!', 'right content';
};

done_testing();
