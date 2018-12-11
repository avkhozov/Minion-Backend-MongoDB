package Minion::Backend::MongoDB;
use Mojo::Base 'Minion::Backend';

our $VERSION = '0.98';

use boolean;
use DateTime;
use Mojo::URL;
use BSON::ObjectId;
use MongoDB;
use Scalar::Util 'weaken';
use Sys::Hostname 'hostname';
use Tie::IxHash;
use Time::HiRes 'time';

has 'mongodb';
has jobs          => sub { $_[0]->mongodb->coll($_[0]->prefix . '.jobs') };
has notifications => sub { $_[0]->mongodb->coll($_[0]->prefix . '.notifications') };
has prefix        => 'minion';
has workers       => sub { $_[0]->mongodb->coll($_[0]->prefix . '.workers') };
#has minion        => sub { $_[0]->on_minion_set(@_) };

sub dequeue {
  my ($self, $oid) = @_;

  # Capped collection for notifications
  $self->_notifications;

  # Await notifications
  $self->_await;
  my $job = $self->_try($oid);

  return undef unless $self->_job_info($job);
  return {args => $job->{args}, id => $job->{_id}, task => $job->{task}};
}

sub enqueue {
  my ($self, $task) = (shift, shift);
  my $args    = shift // [];
  my $options = shift // {};

  # Capped collection for notifications
  $self->_notifications;

  my $doc = {
    args    => $args,
    created => DateTime->from_epoch(epoch => time),
    delayed => DateTime->from_epoch(epoch => $options->{delay} ? time + $options->{delay} : 1),
    priority => $options->{priority} // 0,
    state    => 'inactive',
    task     => $task
  };

  my $res = $self->jobs->insert_one($doc);
  my $oid = $res->inserted_id;
  $self->notifications->insert_one({c => 'created'});
  return $oid;
}

sub fail_job { shift->_update(1, @_) }

sub finish_job { shift->_update(0, @_) }

sub job_info { $_[0]->_job_info($_[0]->jobs->find_one({_id => BSON::OID->new(oid => "$_[1]")})); }

sub list_jobs {
  my ($self, $lskip, $llimit, $options) = @_;

  my $imatch    = {};
  $options->{'_ids'} = [map(BSON::ObjectId->new($_), @{$options->{ids}})]
    if $options->{ids};
  foreach (qw(_id state task queue)) {
      $imatch->{$_} = {'$in' => $options->{$_ . 's'}} if $options->{$_ . 's'};
  }

  my $match     = { '$match' => $imatch };
  my $lookup    = {'$lookup' => {
      from          => 'minion.jobs',
      localField    => '_id',
      foreignField  => 'parents',
      as            => 'children'
  }};
  my $skip      = { '$skip'     => $lskip },
  my $limit     = { '$limit'    => $llimit },
  my $sort      = { '$sort'     => { _id => -1 } };
  my $iproject  = {};
  foreach (qw(_id args attempts children notes priority queue result
    retries state task worker)) {
        $iproject->{$_} = 1;
  }
  foreach (qw(parents)) {
        $iproject->{$_} = { '$ifNull' =>  ['$' . $_ , [] ]};
  }
  foreach (qw(created delayed finished retried started)) {
        $iproject->{$_} = {'$toLong' => {'$multiply' => [{
            '$convert' => { 'input' => '$'. $_, to => 'long'}}, 0.001]}};
  }
  $iproject->{total} = { '$size' => '$children'};
  my $project   = { '$project' => $iproject};

  my $aggregate = [$match, $lookup, $skip, $limit, $sort, $project];


  my $cursor = $self->jobs->aggregate($aggregate);

  #print Data::Dumper::Dumper($options);
  #print Data::Dumper::Dumper($match);
  my $jobs = [map { {id => $_->{_id}, %$_} } $cursor->all];
  my $ret = { total => scalar(@$jobs), jobs => $jobs};
  #print Data::Dumper::Dumper($ret);
  return $ret;
}

# da implementare
#sub list_locks {
#  my ($self, $offset, $limit, $options) = @_;

#  my $locks = $self->pg->db->query(
#    'select name, extract(epoch from expires) as expires,
#       count(*) over() as total from minion_locks
#     where expires > now() and (name = any ($1) or $1 is null)
#     order by id desc limit $2 offset $3', $options->{names}, $limit, $offset
#  )->hashes->to_array;
#  return _total('locks', $locks);
#}


sub list_workers {
  my ($self, $skip, $limit) = @_;
  my $cursor = $self->workers->find({pid => {'$exists' => true}});
  $cursor->sort({_id => -1})->skip($skip)->limit($limit);
  my $workers =  [map { $self->_worker_info($_) } $cursor->all];
  return _total('workers', $workers);
}

sub _total {
  my ($name, $results) = @_;
  my $total = @$results ? $results->[0]{total} : 0;
  delete $_->{total} for @$results;
  return {total => $total, $name => $results};
}

sub new {
  my ($class, $url) = @_;
  my $client = MongoDB::MongoClient->new(
    host                => $url,
    connect_timeout_ms  => 300000,
    socket_timeout_ms   => 300000,
  );
  my $db = $client->db($client->db_name);
  return $class->SUPER::new(mongodb => $db);
}


#sub minion {
#  say qq(New minion set);
#}

sub minion {
  # every time worker dequeue we must reconnect db
  my ($self, $minion)      = @_;

  return $self->{minion} unless $minion;

  $self->{minion} = $minion;
  weaken $self->{minion};

  #say qq("New minion set");

  $minion->on(worker => sub {
      my ($minion, $worker) = @_;
      #$worker->on(dequeue => sub {
      #    my ($worker, $job, $pid) = @_;
      #    my ($id, $task) = ($job->id, $job->task);
      #    say qq{Process $pid is performing job "$id" with task "$task" - Reconnect DB};
      #    #say qq{Reconnect DB};
      #    $worker->self->mongodb->client->reconnect();
      #})
      $worker->on(dequeue => sub { pop->once(spawn => \&_spawn) } );
  });
}
sub _spawn {
  my ($job, $pid) = @_;
  my ($id, $task) = ($job->id, $job->task);
  #say qq{Process $pid is performing job "$id" with task "$task" - Reconnect DB};
  $job->minion->backend->mongodb->client->reconnect();
}

sub note {
  my ($self, $id, $merge) = @_;

  return $self->workers->find_one_and_update(
    {_id => $id},
    {'$set' => {notes => $merge}},
    {
        upsert    => 0,
        returnDocument => 'after',
    }
  )
}

sub receive {
  my ($self, $id) = @_;
  #my $array = shift->pg->db->query(
  #  "update minion_workers as new set inbox = '[]'
  #   from (select id, inbox from minion_workers where id = ? for update)
  #   as old
  #   where new.id = old.id and old.inbox != '[]'
  #   returning old.inbox", shift
  #)->expand->array;

  my $oldrec = $self->workers->find_one_and_update(
    {_id => $id, inbox => { '$exists' => 1, '$ne' => [] } },
    {'$set' => {inbox => [] }},
    {
        upsert    => 0,
        returnDocument => 'before',
    }
  );

  return $oldrec ? $oldrec->inbox // [] : [];
}


sub register_worker {
  my ($self, $id, $options) = @_;

  return $id
    if $id
    && $self->workers->find_one_and_update(
    {_id => $id}, {'$set' => {notified => DateTime->from_epoch(epoch => time)}});

  $self->jobs->indexes->create_one(Tie::IxHash->new(state => 1, delayed => 1, task => 1));
  my $res = $self->workers->insert_one(
    { host     => hostname,
      pid      => $$,
      started  => DateTime->from_epoch(epoch => time),
      notified => DateTime->from_epoch(epoch => time),
      status => $options->{status} // {},
      inbox => [],
    }
  );

  return $res->inserted_id;
}

sub remove_job {
  my ($self, $oid) = @_;
  my $doc = {_id => $oid, state => {'$in' => [qw(failed finished inactive)]}};
  return !!$self->jobs->remove($doc)->{n};
}

sub repair {
  my $self   = shift;
  my $minion = $self->minion;

  # Check worker registry
  my $workers = $self->workers;

  $workers->delete_one({notified => {'$lt' => DateTime->from_epoch(epoch => time - $minion->missing_after)}});

  # Abandoned jobs
  my $jobs = $self->jobs;
  my $cursor = $jobs->find({state => 'active'});
  while (my $job = $cursor->next) {
    $jobs->update_one(
      { _id => $job->{_id}},
      {'$set' => {
        finished => DateTime->from_epoch(epoch => time),
        state    => 'failed',
        result   => 'Worker went away'
       }},
       {upsert => 0}
    ) unless $workers->find_one({_id => $job->{worker}});
  }

  # Old jobs
  $jobs->delete_one(
    {state => 'finished', finished => {'$lt' => DateTime->from_epoch(epoch => time - $minion->remove_after)}}
  );
}

sub reset { $_->drop for $_[0]->workers, $_[0]->jobs }

sub retry_job {
  my ($self, $oid) = (shift, shift);
  my $options = shift // {};

  my $query = {_id => $oid, state => {'$in' => [qw(failed finished)]}};
  my $update = {
    '$inc' => {retries => 1},
    '$set' => {
      retried => DateTime->from_epoch(epoch => time),
      state   => 'inactive',
      delayed => DateTime->from_epoch(epoch => $options->{delay} ? time + $options->{delay} : 1)
    },
    '$unset' => {map { $_ => '' } qw(finished result started worker)}
  };

  return !!$self->jobs->update($query, $update)->{n};
}

sub stats {
  my $self = shift;

  my $jobs = $self->jobs;
  my $active =
    @{$self->mongodb->run_command([distinct => $jobs->name, key => 'worker', query => {state => 'active'}])
      ->{values}};
  my $all = $self->workers->count_documents({});
  my $stats = {active_workers => $active, inactive_workers => $all - $active};
  $stats->{"${_}_jobs"} = $jobs->count_documents({state => $_}) for qw(active failed finished inactive);
  return $stats;
}

sub unregister_worker { shift->workers->delete_one({_id => shift}) }

sub worker_info { $_[0]->_worker_info($_[0]->workers->find_one({_id => $_[1]})) }

sub _await {
  my $self = shift;

  my $last = $self->{last} //= BSON::OID->new;
  my $cursor = $self->notifications->find({_id => {'$gt' => $last}, c => 'created'})->tailable(1);
  return undef unless my $doc = $cursor->next || $cursor->next;
  $self->{last} = $doc->{_id};
  return 1;
}

sub _job_info {
  my $self = shift;

  return undef unless my $job = shift;
  return {
    args     => $job->{args},
    attempts => $job->{attempts} ? $job->{attempts}->value : undef,,
    created  => $job->{created} ? $job->{created}->value : undef,
    delayed  => $job->{delayed} ? $job->{delayed}->value : undef,
    finished => $job->{finished} ? $job->{finished}->value : undef,
    id       => $job->{_id},
    priority => $job->{priority},
    result   => $job->{result},
    retried  => $job->{retried} ? $job->{retried}->value : undef,
    retries => $job->{retries} // 0,
    started => $job->{started} ? $job->{started}->value : undef,
    state   => $job->{state},
    task    => $job->{task},
    parents  => $job->{parents},
    children  => $job->{children},
    queue  => $job->{queue},
    worker  => $job->{worker},
    total  => $job->{total},
  };
}

sub _notifications {
  my $self = shift;

  # We can only await data if there's a document in the collection
  $self->{capped} ? return : $self->{capped}++;
  my $notifications = $self->notifications;
  return if grep { $_ eq $notifications->name } $self->mongodb->collection_names;

  $self->mongodb->run_command([create => $notifications->name, capped => 1, size => 1048576, max => 128]);
  $notifications->insert_one({});
}

sub _try {
  my ($self, $oid) = @_;

  #my $doc = {
  #  query => Tie::IxHash->new(
  #    delayed => {'$lt' => DateTime->from_epoch(epoch => time)},
  #    state   => 'inactive',
  #    task => {'$in' => [keys %{$self->minion->tasks}]}
  #  ),
  #  fields => {args     => 1, task => 1},
  #  sort   => {priority => -1},
  #  update => {'$set' => {started => DateTime->from_epoch(epoch => time), state => 'active', worker => $oid}},
  #  new    => 1
  #};
  my $doc = [
    Tie::IxHash->new(
      delayed => {'$lt' => DateTime->from_epoch(epoch => time)},
      state   => 'inactive',
      task => {'$in' => [keys %{$self->minion->tasks}]}
    ),
    {'$set' => {started => DateTime->from_epoch(epoch => time), state => 'active', worker => $oid}},
    {
        projection => {args     => 1, task => 1},
        sort   => {priority => -1},
        upsert    => 0,
        returnDocument => 'after',
    }
  ];

  return $self->jobs->find_one_and_update(@$doc);
}

sub _update {
  my ($self, $fail, $oid, $retries, $result) = @_;

  my $update = {
      finished => DateTime->from_epoch(epoch => time),
      state => $fail ? 'failed' : 'finished',
      result => $result,
  };
  my $query = {_id => $oid, state => 'active', retries => $retries};
  my $res = $self->jobs->update_one($query, {'$set' => $update});
  return !!$res->matched_count;
}

sub _worker_info {
  my $self = shift;

  return undef unless my $worker = shift;

  my $cursor = $self->jobs->find({state => 'active', worker => $worker->{_id}});
  return {
    host     => $worker->{host},
    id       => $worker->{_id},
    jobs     => [map { $_->{_id} } $cursor->all],
    pid      => $worker->{pid},
    started  => $worker->{started}->epoch,
    notified => $worker->{notified}->epoch
  };
}

1;

=encoding utf8

=head1 NAME

Minion::Backend::MongoDB - MongoDB backend for Minion

=head1 SYNOPSIS

  use Minion::Backend::MongoDB;

  my $backend = Minion::Backend::MongoDB->new('mongodb://127.0.0.1:27017');

=head1 DESCRIPTION

L<Minion::Backend::MongoDB> is a L<MongoDB> backend for L<Minion>.

=head1 ATTRIBUTES

L<Minion::Backend::MongoDB> inherits all attributes from L<Minion::Backend> and
implements the following new ones.

=head2 mongodb

  my $mongodb = $backend->mongodb;
  $backend  = $backend->mongodb(MongoDB->new);

L<MongoDB::Database> object used to store collections.

=head2 jobs

  my $jobs = $backend->jobs;
  $backend = $backend->jobs(MongoDB::Collection->new);

L<MongoDB::Collection> object for C<jobs> collection, defaults to one based on L</"prefix">.

=head2 notifications

  my $notifications = $backend->notifications;
  $backend          = $backend->notifications(MongoDB::Collection->new);

L<MongoDB::Collection> object for C<notifications> collection, defaults to one based on L</"prefix">.

=head2 prefix

  my $prefix = $backend->prefix;
  $backend   = $backend->prefix('foo');

Prefix for collections, defaults to C<minion>.

=head2 workers

  my $workers = $backend->workers;
  $backend    = $backend->workers(MongoDB::Collection->new);

L<MongoDB::Collection> object for C<workers> collection, defaults to one based on L</"prefix">.

=head1 METHODS

L<Minion::Backend::MongoDB> inherits all methods from L<Minion::Backend> and implements the following new ones.

=head2 dequeue

  my $info = $backend->dequeue($worker_id, 0.5);

Wait for job, dequeue it and transition from C<inactive> to C<active> state or
return C<undef> if queue was empty.

=head2 enqueue

  my $job_id = $backend->enqueue('foo');
  my $job_id = $backend->enqueue(foo => [@args]);
  my $job_id = $backend->enqueue(foo => [@args] => {priority => 1});

Enqueue a new job with C<inactive> state. These options are currently available:

=over 2

=item delay

  delay => 10

Delay job for this many seconds from now.

=item priority

  priority => 5

Job priority, defaults to C<0>.

=back

=head2 fail_job

  my $bool = $backend->fail_job($job_id);
  my $bool = $backend->fail_job($job_id, 'Something went wrong!');

Transition from C<active> to C<failed> state.

=head2 finish_job

  my $bool = $backend->finish_job($job_id);

Transition from C<active> to C<finished> state.

=head2 job_info

  my $info = $backend->job_info($job_id);

Get information about a job or return C<undef> if job does not exist.

=head2 list_jobs

  my $batch = $backend->list_jobs($skip, $limit);
  my $batch = $backend->list_jobs($skip, $limit, {state => 'inactive'});

Returns the same information as L</"job_info"> but in batches.

These options are currently available:

=over 2

=item state

  state => 'inactive'

List only jobs in this state.

=item task

  task => 'test'

List only jobs for this task.

=back

=head2 list_workers

  my $batch = $backend->list_workers($skip, $limit);

Returns the same information as L</"worker_info"> but in batches.

=head2 new

  my $backend = Minion::Backend::MongoDB->new('mongodb://127.0.0.1:27017');

Construct a new L<Minion::Backend::MongoDB> object.

=head2 register_worker

  my $worker_id = $backend->register_worker;
  my $worker_id = $backend->register_worker($worker_id);

Register worker or send heartbeat to show that this worker is still alive.

=head2 remove_job

  my $bool = $backend->remove_job($job_id);

Remove C<failed>, C<finished> or C<inactive> job from queue.

=head2 repair

  $backend->repair;

Repair worker registry and job queue if necessary.

=head2 reset

  $backend->reset;

Reset job queue.

=head2 retry_job

  my $bool = $backend->retry_job($job_id);
  my $bool = $backend->retry_job($job_id, {delay => 10});

Transition from C<failed> or C<finished> state back to C<inactive>.

These options are currently available:

=over 2

=item delay

  delay => 10

Delay job for this many seconds (from now).

=back

=head2 stats

  my $stats = $backend->stats;

Get statistics for jobs and workers.

=head2 unregister_worker

  $backend->unregister_worker($worker_id);

Unregister worker.

=head2 worker_info

  my $info = $backend->worker_info($worker_id);

Get information about a worker or return C<undef> if worker does not exist.

=head1 AUTHOR

Andrey Khozov E<lt>avkhozov@gmail.comE<gt>

=head1 LICENSE

Copyright (C) 2015, Andrey Khozov.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=head1 SEE ALSO

L<Minion>, L<MongoDB>, L<http://mojolicio.us>.

=cut
