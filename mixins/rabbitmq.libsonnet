// RabbitMQ, from the OTel rabbitmq receiver's native metrics.
//
// Not CloudWatch: rabbitmq.* metrics land in the sum table as non-monotonic
// sums read directly as Value, and the *_details.rate series are rates the
// management API pre-computes — so no counter-delta machinery here either.
// The service axis is the ServiceName column itself.
//
// Ported from a hand-built reference dashboard, corrected rather than copied:
//
//   - The reference had NO environment predicate anywhere and pinned
//     ServiceName with a custom variable hardcoding one real deployment's
//     name. Scoping now comes from the identity contract (layering rule 3)
//     and the service axis is an env-scoped query dropdown.
//   - rabbitmq.consumer.count and rabbitmq.message.current are recorded per
//     queue (the reference's own Queues tile counts distinct queue names),
//     so its bare max(Value) tiles showed the busiest single queue under
//     titles that read as totals. These now sum per-queue maxima.
//   - Two panels titled "Messages published / routed" actually chart
//     queue_index_write/read_count_details.rate — disk queue-index activity —
//     and are retitled to what they measure.
//   - rabbitmq.node.mem_used is bytes; the reference labelled the panel
//     `short` while its disk sibling correctly used bytes.
local ch = import '../core/sql.libsonnet';
local manifest = import '../core/manifest.libsonnet';
local p = import '../core/panels.libsonnet';

local queueAttr = ch.resAttr('rabbitmq.queue.name');
local nodeAttr = ch.resAttr('rabbitmq.node.name');

// Deliberately NOT $conditionalTest, same stance as ch.envIn: an empty
// selection must yield no rows, and "All" expands to explicit values.
local svcIn = 'ServiceName IN (${service:singlequote})';

// ServiceName leads for the primary index, then MetricName — the same order
// ch.metricPredicates enforces; spelled out here because the service is
// variable-driven rather than a literal.
local preds(s, metric, extra=[]) =
  [svcIn, "MetricName = '" + metric + "'", ch.recorded, s.envPredicate] + extra;

local target(s, query) =
  p.target(s.datasourceUid, s.database, ch.tables.sum, query);

// A per-node line: gauges and management-API rates, read as the bucket max.
local nodeSeries(s, metric) =
  target(s, ch.timeSeriesQuery(
    s.database, ch.tables.sum, metric, 'max(Value)', 'value',
    preds(s, metric),
    groupBy=[nodeAttr + ' AS node'],
  ));

// The broker-wide total of a per-queue metric: each queue's bucket max,
// summed across queues. A bare max(Value) would be the busiest queue alone.
local perQueueTotal(s, metric, extra=[]) =
  target(s, std.join('\n', [
    'SELECT t, sum(v) AS value',
    'FROM (',
    ch.indent(ch.timeSeriesQuery(
      s.database, ch.tables.sum, metric, 'max(Value)', 'v',
      preds(s, metric, extra),
      groupBy=[queueAttr + ' AS queue'],
    )),
    ')',
    'GROUP BY t',
    'ORDER BY t',
  ]) + '\n');

local distinctCount(s, metric, attr) =
  target(s, ch.timeSeriesQuery(
    s.database, ch.tables.sum, metric, 'count(DISTINCT ' + attr + ')', 'value',
    preds(s, metric),
  ));

local stateIs(state) = ch.dim('state') + " = '" + state + "'";

// ---- the service variable ---------------------------------------------------

// Which rabbitmq-instrumented services exist inside the scope. Probes
// rabbitmq.message.current — the one metric every rabbitmq receiver records.
local serviceVariable(s) = {
  name: 'service',
  label: 'Service',
  type: 'query',
  multi: true,
  includeAll: true,
  // No custom allValue: `*` would break the IN clause.
  allValue: null,
  refresh: 1,
  datasource: { type: manifest.datasourceType, uid: s.datasourceUid },
  query: std.join('\n', [
    'SELECT DISTINCT ServiceName AS service',
    ch.from(s.database, ch.tables.sum),
    ch.where([
      ch.variableWindow,
      "MetricName = 'rabbitmq.message.current'",
      ch.recorded,
      s.envPredicate,
    ]),
    'ORDER BY service',
  ]) + '\n',
  current: {},
  options: [],
  hide: 0,
};

// ---- panels -----------------------------------------------------------------

local statGrid(i) = { h: 6, w: 4, x: i * 4, y: 0 };

local panels(s) = [
  p.stat(1, 'Queues', statGrid(0),
         [distinctCount(s, 'rabbitmq.message.current', queueAttr)]),
  p.stat(2, 'Consumers', statGrid(1),
         [perQueueTotal(s, 'rabbitmq.consumer.count')]),
  p.stat(3, 'Nodes', statGrid(2),
         [distinctCount(s, 'rabbitmq.message.current', nodeAttr)]),
  p.stat(4, 'Unacknowledged Messages', statGrid(3),
         [perQueueTotal(s, 'rabbitmq.message.current', [stateIs('unacknowledged')])]),
  p.stat(5, 'Ready Messages', statGrid(4),
         [perQueueTotal(s, 'rabbitmq.message.current', [stateIs('ready')])]),
  // Channels created since node start — the receiver has no current-channels
  // gauge; kept from the reference with its meaning noted.
  p.stat(6, 'Channels', statGrid(5),
         [target(s, ch.timeSeriesQuery(
           s.database, ch.tables.sum, 'rabbitmq.node.channel_created',
           'max(Value)', 'value',
           preds(s, 'rabbitmq.node.channel_created'),
         ))]),

  p.row(7, 'Nodes', 6, collapsed=true, panels=[
    p.timeseries(8, 'Memory Usage', { h: 8, w: 12, x: 0, y: 7 },
                 [nodeSeries(s, 'rabbitmq.node.mem_used')], unit='bytes') + p.legend(),
    p.timeseries(9, 'Free disk', { h: 8, w: 12, x: 12, y: 7 },
                 [nodeSeries(s, 'rabbitmq.node.disk_free')], unit='bytes') + p.legend(),
  ]),

  p.row(10, 'Queued Messages', 7, collapsed=true, panels=[
    p.timeseries(11, 'Messages ready to be delivered to consumers',
                 { h: 8, w: 12, x: 0, y: 8 },
                 [perQueueTotal(s, 'rabbitmq.message.current', [stateIs('ready')])],
                 unit='short') + p.legend(),
    p.timeseries(12, 'Messages pending consumer acknowledgement',
                 { h: 8, w: 12, x: 12, y: 8 },
                 [perQueueTotal(s, 'rabbitmq.message.current', [stateIs('unacknowledged')])],
                 unit='short') + p.legend(),
  ]),

  p.row(13, 'Incoming Messages', 8, collapsed=true, panels=[
    p.timeseries(14, 'Queue index writes / s', { h: 8, w: 12, x: 0, y: 9 },
                 [nodeSeries(s, 'rabbitmq.node.queue_index_write_count_details.rate')],
                 unit='short') + p.legend(),
    p.timeseries(15, 'Queue index reads / s', { h: 8, w: 12, x: 12, y: 9 },
                 [nodeSeries(s, 'rabbitmq.node.queue_index_read_count_details.rate')],
                 unit='short') + p.legend(),
  ]),

  p.row(16, 'Queues', 9, collapsed=true, panels=[
    p.timeseries(17, 'Queues created / s', { h: 7, w: 8, x: 0, y: 10 },
                 [nodeSeries(s, 'rabbitmq.node.queue_created_details.rate')],
                 unit='short') + p.legend(),
    p.timeseries(18, 'Queues deleted / s', { h: 7, w: 8, x: 8, y: 10 },
                 [nodeSeries(s, 'rabbitmq.node.queue_deleted_details.rate')],
                 unit='short') + p.legend(),
    p.timeseries(19, 'Queues declared / s', { h: 7, w: 8, x: 16, y: 10 },
                 [nodeSeries(s, 'rabbitmq.node.queue_declared_details.rate')],
                 unit='short') + p.legend(),
  ]),

  p.row(20, 'Channels', 10, collapsed=true, panels=[
    p.timeseries(21, 'Channels opened / s', { h: 7, w: 12, x: 0, y: 11 },
                 [nodeSeries(s, 'rabbitmq.node.channel_created_details.rate')],
                 unit='short') + p.legend(),
    p.timeseries(22, 'Channels closed / s', { h: 7, w: 12, x: 12, y: 11 },
                 [nodeSeries(s, 'rabbitmq.node.channel_closed_details.rate')],
                 unit='short') + p.legend(),
  ]),

  p.row(23, 'Connections', 11, collapsed=true, panels=[
    p.timeseries(24, 'Connections opened / s', { h: 7, w: 12, x: 0, y: 12 },
                 [nodeSeries(s, 'rabbitmq.node.connection_created_details.rate')],
                 unit='short') + p.legend(),
    p.timeseries(25, 'Connections closed / s', { h: 7, w: 12, x: 12, y: 12 },
                 [nodeSeries(s, 'rabbitmq.node.connection_closed_details.rate')],
                 unit='short') + p.legend(),
  ]),
];

local metricNames = [
  'rabbitmq.message.current',
  'rabbitmq.consumer.count',
  'rabbitmq.node.channel_created',
  'rabbitmq.node.mem_used',
  'rabbitmq.node.disk_free',
  'rabbitmq.node.queue_index_write_count_details.rate',
  'rabbitmq.node.queue_index_read_count_details.rate',
  'rabbitmq.node.queue_created_details.rate',
  'rabbitmq.node.queue_deleted_details.rate',
  'rabbitmq.node.queue_declared_details.rate',
  'rabbitmq.node.channel_created_details.rate',
  'rabbitmq.node.channel_closed_details.rate',
  'rabbitmq.node.connection_created_details.rate',
  'rabbitmq.node.connection_closed_details.rate',
];

{
  name: 'rabbitmq',

  // The rabbitmq.node.* set needs the receiver's node metrics enabled; a
  // collector without them renders six empty collapsed rows. Diff this
  // against your recorded metrics before rendering.
  requires():: { metrics: metricNames },

  dashboards():: [{
    name: 'rabbitmq',
    kind: 'dashboard',
    title: 'RabbitMQ',
    modes: ['scoped', 'browse'],

    build(ctx)::
      local s = ctx.scope;
      p.dashboard(
        title=self.title,
        tags=['rabbitmq'],
        variables=s.variables + [serviceVariable(s)],
        panels=panels(s),
      ),
  }],

  alerts():: [],
}
