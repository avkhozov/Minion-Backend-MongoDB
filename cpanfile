requires Mojolicious => '8.10';
requires Minion => '9.00';
requires MongoDB => '2.0.0';
requires 'DateTime::Span';
requires 'DateTime::Set';

on 'test' => sub {
  requires 'Test::More', '0.98';
};
