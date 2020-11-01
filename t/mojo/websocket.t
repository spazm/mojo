use Mojo::Base -strict;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Test::More;
use Mojo::ByteStream qw(b);
use Mojo::IOLoop;
use Mojo::Promise;
use Mojo::Transaction::WebSocket;
use Mojo::UserAgent;
use Mojolicious::Lite;

subtest "Max WebSocket size" => sub {
  local $ENV{MOJO_MAX_WEBSOCKET_SIZE} = 1024;
  is(Mojo::Transaction::WebSocket->new->max_websocket_size, 1024, 'right value');
};

# Silence
app->log->level('debug')->unsubscribe('message');

# Avoid exception template
app->renderer->paths->[0] = app->home->child('public');

get '/link' => sub {
  my $c = shift;
  $c->render(text => $c->url_for('index')->to_abs);
};

websocket '/' => sub {
  my $c = shift;
  $c->on(finish => sub { shift->stash->{finished}++ });
  $c->on(
    message => sub {
      my ($c, $msg) = @_;
      my $url = $c->url_for->to_abs;
      $c->send("${msg}test2$url");
    }
  );
} => 'index';

get '/something/else' => sub {
  my $c       = shift;
  my $timeout = Mojo::IOLoop->singleton->stream($c->tx->connection)->timeout;
  $c->render(text => "${timeout}failed!");
};

websocket '/early_start' => sub {
  my $c = shift;
  $c->send('test' . ($c->tx->established ? 1 : 0));
  $c->on(
    message => sub {
      my ($c, $msg) = @_;
      $c->send("${msg}test" . ($c->tx->established ? 1 : 0));
      $c->finish(1000 => 'I ♥ Mojolicious!');
    }
  );
};

websocket '/early_finish' => sub {
  my $c = shift;
  Mojo::IOLoop->next_tick(sub { $c->rendered(101)->finish(4000, 'kaboom') });
};

websocket '/denied' => sub {
  my $c = shift;
  $c->tx->handshake->on(finish => sub { $c->stash->{handshake}++ });
  $c->on(finish => sub { shift->stash->{finished}++ });
  $c->render(text => 'denied', status => 403);
};

websocket '/subreq' => sub {
  my $c = shift;
  $c->ua->websocket(
    '/echo' => sub {
      my ($ua, $tx) = @_;
      $tx->on(
        message => sub {
          my ($tx, $msg) = @_;
          $c->send($msg);
          $tx->finish;
          $c->finish;
        }
      );
      $tx->send('test1');
    }
  );
  $c->send('test0');
  $c->on(finish => sub { shift->stash->{finished}++ });
};

websocket '/echo' => sub {
  shift->on(message => sub { shift->send(shift) });
};

websocket '/double_echo' => sub {
  shift->on(
    message => sub {
      my ($c, $msg) = @_;
      $c->send($msg => sub { shift->send($msg) });
    }
  );
};

websocket '/trim' => sub {
  shift->on(message => sub { shift->send(b(shift)->trim) });
};

websocket '/dead' => sub { die 'i see dead processes' };

websocket '/foo' => sub { shift->rendered->res->code('403')->message("i'm a teapot") };

websocket '/close' => sub {
  shift->on(message => sub { Mojo::IOLoop->remove(shift->tx->connection) });
};

websocket '/timeout' => sub {
  shift->inactivity_timeout(0.25)->on(finish => sub { shift->stash->{finished}++ });
};

my $ua  = app->ua;
subtest "URL for WebSocket" => sub {
  my $res = $ua->get('/link')->result;
  is $res->code,   200,                        'right status';
  like $res->body, qr!ws://127\.0\.0\.1:\d+/!, 'right content';
};

subtest "Plain HTTP request" => sub {
  my $res = $ua->get('/early_start')->res;
  is $res->code,   404,                'right status';
  like $res->body, qr/Page not found/, 'right content';
};

subtest "Plain WebSocket" => sub {
  my ($stash, $result);
  app->plugins->once(before_dispatch => sub { $stash = shift->stash });
  $ua->websocket(
    '/' => sub {
      my ($ua, $tx) = @_;
      $tx->on(finish  => sub { Mojo::IOLoop->stop });
      $tx->on(message => sub { shift->finish; $result = shift });
      $tx->send('test1');
    }
  );
  Mojo::IOLoop->start;
  Mojo::IOLoop->one_tick until $stash->{finished};
  is $stash->{finished}, 1, 'finish event has been emitted once';
  like $result, qr!test1test2ws://127\.0\.0\.1:\d+/!, 'right result';
};

subtest "Failed WebSocket connection" => sub {
  my ($code, $body, $ws);
  $ua->websocket(
    '/something/else' => sub {
      my ($ua, $tx) = @_;
      $ws   = $tx->is_websocket;
      $code = $tx->res->code;
      $body = $tx->res->body;
      Mojo::IOLoop->stop;
    }
  );
  Mojo::IOLoop->start;
  ok !$ws, 'not a WebSocket';
  is $code, 200, 'right status';
  ok $body =~ /^(\d+)failed!$/ && $1 == 30, 'right content';
};

subtest "Server directly sends a message" => sub {
  my $result = '';
  my ($established, $status, $msg);
  $ua->websocket(
    '/early_start' => sub {
      my ($ua, $tx) = @_;
      $established = $tx->established;
      $tx->on(
        finish => sub {
          my ($tx, $code, $reason) = @_;
          ($status, $msg) = ($code, $reason);
          Mojo::IOLoop->stop;
        }
      );
      $tx->on(
        message => sub {
          my ($tx, $msg) = @_;
          $result .= $msg;
          $tx->send('test2');
        }
      );
    }
  );
  Mojo::IOLoop->start;
  ok $established, 'connection established';
  is $status,      1000,               'right status';
  is $msg,         'I ♥ Mojolicious!', 'right message';
  is $result,      'test0test2test1',  'right result';
};

subtest "WebSocket connection gets closed very fast" => sub {
  my $status = undef;
  $ua->websocket(
    '/early_finish' => sub {
      my ($ua, $tx) = @_;
      $tx->on(finish => sub { $status = [@_[1, 2]]; Mojo::IOLoop->stop });
    }
  );
  Mojo::IOLoop->start;
  is $status->[0], 4000,     'right status';
  is $status->[1], 'kaboom', 'right message';
};

subtest "Connection denied" => sub {
  my ($stash, $code, $ws) = ();
  app->plugins->once(before_dispatch => sub { $stash = shift->stash });
  $ua->websocket(
    '/denied' => sub {
      my ($ua, $tx) = @_;
      $ws   = $tx->is_websocket;
      $code = $tx->res->code;
      Mojo::IOLoop->stop;
    }
  );
  Mojo::IOLoop->start;
  Mojo::IOLoop->one_tick until $stash->{finished};
  is $stash->{handshake}, 1, 'finish event has been emitted once for handshake';
  is $stash->{finished},  1, 'finish event has been emitted once';
  ok !$ws, 'not a WebSocket';
  is $code, 403, 'right status';
};

subtest "Subrequests" => sub {
  my ($stash, $code, $result) = ();
  app->plugins->once(before_dispatch => sub { $stash = shift->stash });
  $ua->websocket(
    '/subreq' => sub {
      my ($ua, $tx) = @_;
      $code = $tx->res->code;
      $tx->on(message => sub { $result .= pop });
      $tx->on(finish  => sub { Mojo::IOLoop->stop });
    }
  );
  Mojo::IOLoop->start;
  Mojo::IOLoop->one_tick until $stash->{finished};
  is $stash->{finished}, 1, 'finish event has been emitted once';
  is $code,   101,          'right status';
  is $result, 'test0test1', 'right result';
};

subtest "Concurrent subrequests" => sub {
  my $delay = Mojo::IOLoop->delay;
  my ($code, $result) = ();
  my ($code2, $result2);
  my $end = $delay->begin;
  $ua->websocket(
    '/subreq' => sub {
      my ($ua, $tx) = @_;
      $code = $tx->res->code;
      $tx->on(
        message => sub {
          my ($tx, $msg) = @_;
          $result .= $msg;
          $tx->finish if $msg eq 'test1';
        }
      );
      $tx->on(finish => sub { $end->() });
    }
  );
  my $end2 = $delay->begin;
  $ua->websocket(
    '/subreq' => sub {
      my ($ua, $tx) = @_;
      $code2 = $tx->res->code;
      $tx->on(message => sub { $result2 .= pop });
      $tx->on(finish  => sub { $end2->() });
    }
  );
  $delay->wait;
  is $code,    101,          'right status';
  is $result,  'test0test1', 'right result';
  is $code2,   101,          'right status';
  is $result2, 'test0test1', 'right result';
};

subtest "Client-side drain callback" => sub {
  my $result = '';
  my ($drain, $counter);
  $ua->websocket(
    '/echo' => sub {
      my ($ua, $tx) = @_;
      $tx->on(finish => sub { Mojo::IOLoop->stop });
      $tx->on(
        message => sub {
          my ($tx, $msg) = @_;
          $result .= $msg;
          $tx->finish if ++$counter == 2;
        }
      );
      $tx->send(
        'hi!' => sub {
          shift->send('there!');
          $drain += @{Mojo::IOLoop->stream($tx->connection)->subscribers('drain')};
        }
      );
    }
  );
  Mojo::IOLoop->start;
  is $result, 'hi!there!', 'right result';
  is $drain,  1,           'no leaking subscribers';
};

subtest "Server-side drain callback" => sub {
  my $result  = '';
  my $counter = 0;
  $ua->websocket(
    '/double_echo' => sub {
      my ($ua, $tx) = @_;
      $tx->on(finish => sub { Mojo::IOLoop->stop });
      $tx->on(
        message => sub {
          my ($tx, $msg) = @_;
          $result .= $msg;
          $tx->finish if ++$counter == 2;
        }
      );
      $tx->send('hi!');
    }
  );
  Mojo::IOLoop->start;
  is $result, 'hi!hi!', 'right result';
};

subtest "Sending objects" => sub {
  my $result = undef;
  $ua->websocket(
    '/trim' => sub {
      my ($ua, $tx) = @_;
      $tx->on(finish  => sub { Mojo::IOLoop->stop });
      $tx->on(message => sub { shift->finish; $result = shift });
      $tx->send(b(' foo bar '));
    }
  );
  Mojo::IOLoop->start;
  is $result, 'foo bar', 'right result';
};

subtest "Promises" => sub {
  my $result = undef;
  $ua->websocket_p('/trim')->then(sub {
      my $tx      = shift;
      my $promise = Mojo::Promise->new;
      $tx->on(finish  => sub { $promise->resolve });
      $tx->on(message => sub { shift->finish; $result = pop });
      $tx->send(' also works! ');
      return $promise;
    })->wait;
  is $result, 'also works!', 'right result';
  $result = undef;
  $ua->websocket_p('/foo')->then(sub { $result = 'test failed' })->catch(sub { $result = shift })->wait;
  is $result, 'WebSocket handshake failed', 'right result';
  $result = undef;
  $ua->websocket_p($ua->server->url->to_abs->scheme('wsss'))->then(sub { $result = 'test failed' })
  ->catch(sub { $result = shift })->wait;
  is $result, 'Unsupported protocol: wsss', 'right result';
};

subtest "Dies" => sub {
  my ($ws, $code, $msg) = ();
  my $finished;
  $ua->websocket(
    '/dead' => sub {
      my ($ua, $tx) = @_;
      $finished = $tx->is_finished;
      $ws       = $tx->is_websocket;
      $code     = $tx->res->code;
      $msg      = $tx->res->message;
      Mojo::IOLoop->stop;
    }
  );
  Mojo::IOLoop->start;
  ok $finished, 'transaction is finished';
  ok !$ws, 'not a websocket';
  is $code, 500,                     'right status';
  is $msg,  'Internal Server Error', 'right message';
};

subtest "Forbidden" => sub {
  my ($ws, $code, $msg) = ();
  $ua->websocket(
    '/foo' => sub {
      my ($ua, $tx) = @_;
      $ws   = $tx->is_websocket;
      $code = $tx->res->code;
      $msg  = $tx->res->message;
      Mojo::IOLoop->stop;
    }
  );
  Mojo::IOLoop->start;
  ok !$ws, 'not a websocket';
  is $code, 403,            'right status';
  is $msg,  "i'm a teapot", 'right message';
};

subtest "Connection close" => sub {
  my $status = undef;
  $ua->websocket(
    '/close' => sub {
      my ($ua, $tx) = @_;
      $tx->on(finish => sub { $status = pop; Mojo::IOLoop->stop });
      $tx->send('test1');
    }
  );
  Mojo::IOLoop->start;
  is $status, 1006, 'right status';
};

subtest "Unsupported protocol" => sub {
  my $error;
  $ua->websocket(
    'wsss://example.com' => sub {
      my ($ua, $tx) = @_;
      $error = $tx->error;
      Mojo::IOLoop->stop;
    }
  );
  Mojo::IOLoop->start;
  is $error->{message}, 'Unsupported protocol: wsss', 'right error';
};

subtest "16-bit length" => sub {
  my $result = undef;
  $ua->websocket(
    '/echo' => sub {
      my ($ua, $tx) = @_;
      $tx->on(finish  => sub { Mojo::IOLoop->stop });
      $tx->on(message => sub { shift->finish; $result = shift });
      $tx->send('hi!' x 100);
    }
  );
  Mojo::IOLoop->start;
  is $result, 'hi!' x 100, 'right result';
};

subtest "Timeout" => sub {
  my $log = '';
  my $msg   = app->log->on(message => sub { $log .= pop });
  my $stash = undef;
  app->plugins->once(before_dispatch => sub { $stash = shift->stash });
  $ua->websocket(
    '/timeout' => sub {
      pop->on(finish => sub { Mojo::IOLoop->stop });
    }
  );
  Mojo::IOLoop->start;
  Mojo::IOLoop->one_tick until $stash->{finished};
  is $stash->{finished}, 1, 'finish event has been emitted once';
  like $log, qr/Inactivity timeout/, 'right log message';

  app->log->unsubscribe(message => $msg);
};

subtest "Ping/pong" => sub {
  my $pong;
  $ua->websocket(
    '/echo' => sub {
      my ($ua, $tx) = @_;
      $tx->on(
        frame => sub {
          my ($tx, $frame) = @_;
          return unless $frame->[4] == 10;
          $pong = $frame->[5];
          $tx->finish;
        }
      );
      $tx->on(finish => sub { Mojo::IOLoop->stop });
      $tx->send([1, 0, 0, 0, 9, 'test']);
    }
  );
  Mojo::IOLoop->start;
  is $pong, 'test', 'received pong with payload';
};

done_testing();
