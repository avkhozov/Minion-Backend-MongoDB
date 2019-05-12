requires Minion => '1.15';
requires 'MongoDB';
requires 'DateTime';
requires 'Mojo::Base';
requires 'Mojo::URL';
requires 'Tie::IxHash';

on 'test' => sub {
  requires 'Test::More', '0.98';
};
