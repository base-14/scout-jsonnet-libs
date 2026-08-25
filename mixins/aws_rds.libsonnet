// AWS RDS / Aurora, from CloudWatch metric-stream data.
//
// Ported from a hand-built reference dashboard, corrected rather than copied:
//
//   - Environment scoping comes from the identity contract (ctx.scope), never
//     a hand-written predicate — layering rule 3.
//   - Three units checked against the CloudWatch metric reference: the
//     reference labelled CommitLatency (milliseconds), OldestReplicationSlotLag
//     (megabytes of WAL backlog) and WriteThroughput (bytes/second) all as
//     seconds.
//   - The by-cluster CPU panel filtered on DBInstanceIdentifier while
//     splitting on DBClusterIdentifier. Stream datapoints exist per dimension
//     set, so cluster rows carry no instance id and instance rows no cluster
//     id: the filter excluded exactly the rows the split needed, and only
//     appeared to work because $conditionalTest dropped it when nothing was
//     selected. The panel now gates on the cluster dimension instead.
//
// Aggregations are the reference's, kept per panel: max(Sum) where the worst
// period is the signal (latencies, lags, throughput peaks), avg(Sum) for
// level gauges (connections, IOPS, storage, CPU).
local cw = import '../core/cloudwatch.libsonnet';
local p = import '../core/panels.libsonnet';

local metric(name) = cw.metricName('AWS/RDS', name);

local instanceDim = 'DBInstanceIdentifier';
local instanceIn = cw.dimIn(instanceDim, 'dbInstance');

local target(s, refId, name, agg, prefix=null) =
  cw.streamTarget(
    s,
    refId,
    metric(name),
    agg + '(Sum)',
    cw.series(instanceDim, prefix),
    [instanceIn],
  );

local one(s, name, agg) = [target(s, 'A', name, agg)];

local grid(x, y, h=12) = { h: h, w: 12, x: x, y: y };

// ---- panels -----------------------------------------------------------------

local panels(s) = [
  p.timeseries(1, 'Commit Latency', grid(0, 0), one(s, 'CommitLatency', 'max'), unit='ms') + p.legend(),
  p.timeseries(2, 'Engine Uptime', grid(12, 0), one(s, 'EngineUptime', 'avg'), unit='s') + p.legend(),
  p.timeseries(3, 'Deadlocks', grid(0, 12), one(s, 'Deadlocks', 'avg')) + p.bars(stacked=false) + p.legend(),
  p.timeseries(4, 'DB Connections', grid(12, 12), one(s, 'DatabaseConnections', 'avg')) + p.legend(),

  p.row(5, 'Throughputs', 24),
  p.timeseries(6, 'Commit Throughput (per second)', grid(0, 25), one(s, 'CommitThroughput', 'max')) + p.legend(),
  p.timeseries(7, 'Network Throughput (bytes per second)', grid(12, 25), one(s, 'NetworkThroughput', 'max'), unit='bytes') + p.legend(),
  p.timeseries(8, 'Temp Storage Throughput (bytes per second)', grid(0, 37), one(s, 'TempStorageThroughput', 'max'), unit='bytes') + p.legend(),
  p.timeseries(9, 'Storage Network Throughput (bytes per second)', grid(12, 37), one(s, 'StorageNetworkThroughput', 'max'), unit='bytes') + p.legend(),

  p.row(10, 'Lags and Latencies', 49),
  p.timeseries(11, 'Checkpoint Lag', grid(0, 50), one(s, 'CheckpointLag', 'max'), unit='s') + p.legend(),
  p.timeseries(12, 'Aurora Replica Lag', grid(12, 50), one(s, 'AuroraReplicaLag', 'max'), unit='ms') + p.legend(),
  p.timeseries(13, 'Oldest Replication Slot Lag', grid(0, 62), one(s, 'OldestReplicationSlotLag', 'max'), unit='decmbytes') + p.legend(),
  p.timeseries(14, 'RDS To Aurora PostgreSQL Replica Lag', grid(12, 62), one(s, 'RDSToAuroraPostgreSQLReplicaLag', 'max'), unit='s') + p.legend(),

  p.row(15, 'I/O', 74),
  p.timeseries(16, 'Read IOPS', grid(0, 75), one(s, 'ReadIOPS', 'avg')) + p.legend(),
  p.timeseries(17, 'Write IOPS', grid(12, 75), one(s, 'WriteIOPS', 'avg')) + p.legend(),
  p.timeseries(18, 'Read Latency', grid(0, 87), one(s, 'ReadLatency', 'avg'), unit='s') + p.legend(),
  p.timeseries(19, 'Write Latency', grid(12, 87), one(s, 'WriteLatency', 'avg'), unit='s') + p.legend(),
  p.timeseries(20, 'Read Throughput (per second)', grid(0, 99), one(s, 'ReadThroughput', 'avg'), unit='bytes') + p.legend(),
  p.timeseries(21, 'Write Throughput (per second)', grid(12, 99), one(s, 'WriteThroughput', 'avg'), unit='bytes') + p.legend(),
  p.timeseries(22, 'Disk Queue Depth', grid(0, 111), one(s, 'DiskQueueDepth', 'avg')) + p.legend(),
  p.timeseries(23, 'Buffer Cache Hit Ratio', grid(12, 111), one(s, 'BufferCacheHitRatio', 'avg'), unit='percent') + p.legend(),

  p.row(24, 'Storage', 123),
  p.timeseries(25, 'Free Storage Space', grid(0, 124), one(s, 'FreeStorageSpace', 'avg'), unit='bytes') + p.legend(),
  p.timeseries(26, 'Free Local Storage Space', grid(12, 124), [
    target(s, 'A', 'FreeLocalStorage', 'avg', 'Free Local'),
    target(s, 'B', 'FreeEphemeralStorage', 'avg', 'Free Ephemeral'),
  ], unit='bytes') + p.legend(),

  p.row(27, 'Memory', 136),
  p.timeseries(28, 'Freeable Memory', grid(0, 137), one(s, 'FreeableMemory', 'avg'), unit='bytes') + p.legend(),

  p.row(29, 'CPU Utilization', 149),
  p.timeseries(30, 'CPU Utilization by Instance', grid(0, 150, h=9), one(s, 'CPUUtilization', 'avg'), unit='percent') + p.legend(),
  p.timeseries(31, 'DB Load per VCPU', grid(12, 150, h=9), one(s, 'DBLoadRelativeToNumVCPUs', 'avg')) + p.legend(),
  // Split on the cluster id, gated on rows that carry one — never filtered by
  // $dbInstance, whose dimension these rows do not have. See the header.
  p.timeseries(32, 'CPU Utilization by Cluster', grid(0, 159, h=9), [
    cw.streamTarget(
      s,
      'A',
      metric('CPUUtilization'),
      'avg(Sum)',
      cw.series('DBClusterIdentifier'),
      [cw.hasDim('DBClusterIdentifier')],
    ),
  ], unit='percent') + p.legend(),
  p.timeseries(33, 'DB Load Avg', grid(12, 159, h=9), [
    target(s, 'A', 'DBLoad', 'avg', 'DBLoad'),
    target(s, 'B', 'DBLoadCPU', 'avg', 'DBLoadCPU'),
    target(s, 'C', 'DBLoadNonCPU', 'avg', 'DBLoadNonCPU'),
  ]) + p.legend(),
];

// Every metric the panels query, for requires(). Aurora-only entries (commit
// latency/throughput, the lags, local storage, engine uptime) simply never
// record on plain RDS instances — worth knowing before rendering, which is
// what requires() is for.
local metricNames = [
  'CommitLatency',
  'EngineUptime',
  'Deadlocks',
  'DatabaseConnections',
  'CommitThroughput',
  'NetworkThroughput',
  'TempStorageThroughput',
  'StorageNetworkThroughput',
  'CheckpointLag',
  'AuroraReplicaLag',
  'OldestReplicationSlotLag',
  'RDSToAuroraPostgreSQLReplicaLag',
  'ReadIOPS',
  'WriteIOPS',
  'ReadLatency',
  'WriteLatency',
  'ReadThroughput',
  'WriteThroughput',
  'DiskQueueDepth',
  'BufferCacheHitRatio',
  'FreeStorageSpace',
  'FreeLocalStorage',
  'FreeEphemeralStorage',
  'FreeableMemory',
  'CPUUtilization',
  'DBLoadRelativeToNumVCPUs',
  'DBLoad',
  'DBLoadCPU',
  'DBLoadNonCPU',
];

{
  name: 'aws-rds',

  requires():: { metrics: [metric(n) for n in metricNames] },

  dashboards():: [{
    name: 'aws-rds',
    kind: 'dashboard',
    title: 'AWS RDS',
    modes: ['scoped', 'browse'],

    build(ctx)::
      local s = ctx.scope;
      p.dashboard(
        title=self.title,
        tags=['aws', 'rds'],
        variables=s.variables
                  + [cw.dimVariable(s,
                                    'dbInstance',
                                    'DB Instance',
                                    instanceDim,
                                    metric('CPUUtilization'))],
        panels=panels(s),
      ),
  }],

  alerts():: [],
}
