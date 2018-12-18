package Minion::Backend::MongoDB;
use Mojo::Base 'Minion::Backend';

our $VERSION = '0.98';

use boolean;
use DateTime;
use DateTime::Span;
use DateTime::Set;
use Mojo::URL;
use BSON::ObjectId;
use BSON::Types ':all';
use MongoDB;
use Mojo::IOLoop;
use Scalar::Util 'weaken';
use Sys::Hostname 'hostname';
use Tie::IxHash;
use Time::HiRes 'time';

has 'dbclient';
has 'mongodb';
has jobs          => sub { $_[0]->mongodb->coll($_[0]->prefix . '.jobs') };
has notifications => sub { $_[0]->mongodb->coll($_[0]->prefix . '.notifications') };
has prefix        => 'minion';
has workers       => sub { $_[0]->mongodb->coll($_[0]->prefix . '.workers') };
has locks         => sub { $_[0]->mongodb->coll($_[0]->prefix . '.locks') };
has admin         => sub { $_[0]->dbclient->db('admin') };

sub broadcast {
  my ($s, $command, $args, $ids) = (shift, shift, shift || [], shift || []);

  my $res = $s->workers->update_one(
    { _id => {'$in' => $ids} },
    {inbox => [[$command,@$args]]}
  );

  return !!$res->matched_count;
}

sub dequeue {
  my ($self, $oid, $wait, $options) = @_;

  if ((my $job = $self->_try($oid, $options))) { return $job }
  return undef if Mojo::IOLoop->is_running;

  # Capped collection for notifications
  $self->_notifications;

  my $timer = Mojo::IOLoop->timer($wait => sub { Mojo::IOLoop->stop });
  Mojo::IOLoop->subprocess(
    sub {
        sleep 1 until $self->_await;
        Mojo::IOLoop->stop;
    }
  );
  Mojo::IOLoop->start;
  Mojo::IOLoop->remove($timer);

  return $self->_try($oid, $options);

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

sub history {
  my $self = shift;

  my $dt_stop     = DateTime->now;
  my $dt_start    = $dt_stop->clone->add(days => -1);
  my $dt_span     = DateTime::Span->from_datetimes(
    start => $dt_start,
    end => $dt_stop
  );
  my $dt_set      = DateTime::Set->from_recurrence(
    recurrence => sub { return $_[0]->truncate(to=>'hour')->add(hours => 1) }
  );
  my @dt_set      = $dt_set->as_list(span => $dt_span);
  my %acc = (map {&_dtkey($_) => {
      epoch    => $_->epoch(),
      failed_jobs   => 0,
      finished_jobs => 0
  }} @dt_set);

  my $match  = {'$match' => { finished => {'$gt' => $dt_start} } };
  my $group  = {'$group' => {
    '_id'  => {
        hour    => {'$hour' => {date => '$finished'}},
        day     => {'$dayOfYear' => {date => '$finished'}},
        year    => {'$year' => {date => '$finished'}}
    },
    finished_jobs => {'$sum' => {
        '$cond' => {if => {'$eq' => ['$state', 'finished']}, then => 1, else => 0}
    }},
    failed_jobs => {'$sum' => {
        '$cond' => {if => {'$eq' => ['$state', 'failed']}, then => 1, else => 0}
    }}
  }};

  my $cursor = $self->jobs->aggregate([$match, $group]);

  while (my $doc = $cursor->next) {
    my $dt_finished = new DateTime(
        year => $doc->{_id}->{year},
        month => 1,
        day => 1,
        hour => $doc->{_id}->{hour},
    );
    $dt_finished->add(days => $doc->{_id}->{day}-1);
    my $key = &_dtkey($dt_finished);
    $acc{$key}->{$_} += $doc->{$_} for(qw(finished_jobs failed_jobs));
  }

  my @k = sort keys(%acc);

  return {daily => [@acc{(sort keys(%acc))}]};

}

sub _dtkey {
    return substr($_[0]->datetime, 0, -6);
}

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
  my $skip      = { '$skip'     => 0 + $lskip },
  my $limit     = { '$limit'    => 0 + $llimit },
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

  my $cursor    = $self->jobs->aggregate($aggregate);
  my $total     = $self->jobs->count_documents($imatch);

  my $jobs = [map { {id => $_->{_id}, %$_} } $cursor->all];
  return _total('jobs', $jobs, $total);
}

sub list_locks {
  my ($self, $offset, $limit, $options) = @_;

  my %aggregate;
  my $imatch    = {};
  $imatch->{expires} = {'$gt' => bson_time()};
  foreach (qw(name)) {
      $imatch->{$_} = {'$in' => $options->{$_}} if $options->{$_};
  }
  $aggregate{match}     = { '$match' => $imatch };
  $aggregate{skip}      = { '$skip'     => $offset // 0 },
  $aggregate{limit}     = { '$limit'    => $limit } if ($limit);

  my $iproject  = {};
  foreach (qw(expires)) {
        $iproject->{$_} = {'$toLong' => {'$multiply' => [{
            '$convert' => { 'input' => '$'. $_, to => 'long'}}, 0.001]}};
  }
  foreach (qw(name)) {
        $iproject->{$_} = 1;
  }
  $aggregate{project}   = { '$project' => $iproject};
  $aggregate{sort}      = { '$sort'     => { _id => -1 } };

  my @aggregate = grep defined, map {$aggregate{$_}}
   qw(match skip limit sort project);

  my $cursor    = $self->locks->aggregate(\@aggregate);
  my $total     = $self->locks->count_documents($imatch);

  my $locks = [$cursor->all];

  return _total('locks', $locks, $total);
}

sub list_workers {
  my ($self, $skip, $limit) = @_;
  my $cursor = $self->workers->find({pid => {'$exists' => true}});
  my $total = scalar($cursor->all);
  $cursor->reset;
  $cursor->sort({_id => -1})->skip($skip)->limit($limit);
  my $workers =  [map { $self->_worker_info($_) } $cursor->all];
  return _total('workers', $workers, $total);
}

sub lock {
  my ($s, $name, $duration, $options) = (shift, shift, shift, shift // {});
  return $s->_lock($name, $duration, $options->{limit}||1);
}

sub new {
  my ($class, $url) = @_;
  my $client = MongoDB::MongoClient->new(
    host                => $url,
    connect_timeout_ms  => 300000,
    socket_timeout_ms   => 300000,
  );
  my $db = $client->db($client->db_name);

  my $self = $class->SUPER::new(dbclient => $client, mongodb => $db);
  Mojo::IOLoop->singleton->on(reset => sub {
      $self->mongodb->client->reconnect();
  });

  return $self;
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
  ) ? 1 : 0;
}

sub receive {
  my ($self, $id) = @_;
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
  $self->jobs->indexes->create_one(Tie::IxHash->new(finished => 1));
  $self->locks->indexes->create_one(Tie::IxHash->new(name => 1, expires => 1));
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
  return !!$self->jobs->delete_one($doc)->deleted_count;
}

sub repair {
  my $self   = shift;
  my $minion = $self->minion;

  # Check worker registry
  my $workers = $self->workers;

  $workers->delete_many({notified => {
      '$lt' => DateTime->from_epoch(epoch => time - $minion->missing_after)}});

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
  $jobs->delete_many(
    {state => 'finished', finished => {
        '$lt' => DateTime->from_epoch(epoch => time - $minion->remove_after)}}
  );
}

sub reset { $_->drop for $_[0]->workers, $_[0]->jobs, $_[0]->locks }

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

  my $res = $self->jobs->update_one($query, $update);
  return !!$res->matched_count;
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
  $stats->{active_locks} = $self->list_locks->{total};
  $stats->{delayed_jobs} = $self->jobs->count_documents({
      state => 'inactive',
      delayed => {'$gt' => bson_time}
  });
  # I don't know if this value is correct as calculated. PG use the incremental
  # sequence id
  $stats->{enqueued_jobs} += $stats->{"${_}_jobs"} for qw(active failed finished inactive);
  $stats->{uptime} = $self->admin->run_command(Tie::IxHash->new('serverStatus' => 1))->{uptime};
  return $stats;
}

sub unlock {
    my ($s, $name) = @_;

    my $res = $s->locks->delete_many({
        name => $name,
        expires => {'$gt' => bson_time()}
    });

    return !!$res->deleted_count;
}
sub unregister_worker { shift->workers->delete_one({_id => shift}) }

sub worker_info { $_[0]->_worker_info($_[0]->workers->find_one({_id => $_[1]})) }

sub _await {
  my $self = shift;

  my $last = $self->{last} //= BSON::OID->new;
  # TODO: Implement update_retries on job update retries field
  my $cursor = $self->notifications->find({
    _id => {'$gt' => $last},
    '$or' =>  [
        { c => 'created'},
        { c => 'update_retries'}
    ]
  })->tailable(1);
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

sub _lock {
    my ($s, $name, $duration, $count) = @_;

    my $dtNow = DateTime->now;
    my $dtExp = $dtNow->clone->add(seconds => $duration);

    $s->locks->delete_many({expires => {'$lt' => $dtNow}});

    return 0
        if ($s->locks->count_documents({name => $name}) >= $count );

    $s->locks->insert_one({
        name => $name, expires => $dtExp
    }) if ($dtExp > $dtNow);

    return 1;
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

sub _total {
    my ($name, $res, $tot) = @_;
    return { total => $tot, $name => $res};
}

sub _try {
  my ($self, $oid, $options) = @_;

  # TODO: Implement $options

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

  my $job = $self->jobs->find_one_and_update(@$doc);
  return undef unless ($job->{_id});
  $job->{id} = $job->{_id};
  return $job;
}

sub _update {
  my ($self, $fail, $oid, $retries, $result) = @_;

  my $update = {
      finished => DateTime->from_epoch(epoch => time),
      state => $fail ? 'failed' : 'finished',
      result => $fail ?  $result . '' : $result ,
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

=head1 NOTES ABOUT USER

User must have this roles

  "roles" : [
                {
                        "role" : "dbAdmin",
                        "db" : "minion"
                },
                {
                        "role" : "clusterMonitor",
                        "db" : "admin"
                },
                {
                        "role" : "readWrite",
                        "db" : "minion"
                }
        ]

=head1 AUTHORS

Andrey Khozov E<lt>avkhozov@gmail.comE<gt>
Emiliano Bruni E<lt>info@ebruni.itE<gt>

=head1 LICENSE

Copyright (C) 2015, Andrey Khozov, Emiliano Bruni.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=head1 SEE ALSO

L<Minion>, L<MongoDB>, L<http://mojolicio.us>.

=cut
