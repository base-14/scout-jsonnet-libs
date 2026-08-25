// AWS Application ELB, from CloudWatch metric-stream data.
//
// Ported from a hand-built reference dashboard, with its silent failures
// corrected rather than copied:
//
//   - Environment scoping comes from the identity contract (ctx.scope), never
//     a hand-written predicate — layering rule 3.
//   - The reference paired each MetricName with a redundant
//     Attributes['MetricName'] predicate, and four of the copies contradicted
//     the metric next to them (Anomalous/Mitigated hosts, Target 5xx) — valid
//     SQL, permanently empty series. The column predicate already pins the
//     metric, so the datapoint copy is dropped entirely.
//   - Two panels carried Grpc/IPv6 request-count targets pasted in from the
//     Request Count panel (one plotted counts on a bytes axis); the 5xx panel
//     queried 502 twice and 504 never.
local cw = import '../core/cloudwatch.libsonnet';
local p = import '../core/panels.libsonnet';

local metric(name) = cw.metricName('AWS/ApplicationELB', name);

local lbDim = 'LoadBalancer';
local lbIn = cw.dimIn(lbDim, 'loadBalancer');

// The stream metric's value is the bucket's Sum (see cloudwatch.libsonnet);
// max() collapses the stream's multiple dimension sets per bucket instead of
// double-counting them, matching the reference.
local target(s, refId, name, prefix) =
  cw.streamTarget(s, refId, metric(name), 'max(Sum)', cw.series(lbDim, prefix), [lbIn]);

// specs: [{ metric, prefix }]
local targets(s, specs) = std.mapWithIndex(
  function(i, spec) target(s, std.char(65 + i), spec.metric, spec.prefix),
  specs,
);

// The reference singled out unhealthy hosts in red via /.Healthy*/ — a regex
// that only ever matched "UnHealthy". Same intent, said plainly.
local unhealthyRed = {
  fieldConfig+: { overrides: [{
    matcher: { id: 'byRegexp', options: '/^UnHealthy.*/' },
    properties: [{ id: 'color', value: { fixedColor: 'dark-red', mode: 'fixed' } }],
  }] },
};

// ---- panels -----------------------------------------------------------------

local panels(s) = [
  p.timeseries(1, 'Host Counts by Status', { h: 11, w: 6, x: 0, y: 0 }, targets(s, [
    { metric: 'HealthyHostCount', prefix: 'Healthy' },
    { metric: 'AnomalousHostCount', prefix: 'Anomalous' },
    { metric: 'UnHealthyHostCount', prefix: 'UnHealthy' },
    { metric: 'MitigatedHostCount', prefix: 'Mitigated' },
  ])) + p.bars() + p.legend('table') + unhealthyRed,

  p.timeseries(2, 'DNS by Status', { h: 11, w: 6, x: 6, y: 0 }, targets(s, [
    { metric: 'HealthyStateDNS', prefix: 'HealthyDNS' },
    { metric: 'UnhealthyStateDNS', prefix: 'UnhealthyDNS' },
  ])) + p.bars() + p.legend(),

  p.timeseries(3, 'PeakLCUs', { h: 11, w: 6, x: 12, y: 0 }, targets(s, [
    { metric: 'PeakLCUs', prefix: 'PeakLCUs' },
  ])) + p.bars() + p.legend(),

  p.timeseries(4, 'RuleEvaluations', { h: 11, w: 6, x: 18, y: 0 }, targets(s, [
    { metric: 'RuleEvaluations', prefix: 'RuleEvaluations' },
  ])) + p.bars() + p.legend(),

  p.timeseries(5, 'ELB Response Counts by Code', { h: 11, w: 12, x: 0, y: 11 }, targets(s, [
    { metric: 'HTTPCode_ELB_3XX_Count', prefix: '3xx' },
    { metric: 'HTTPCode_ELB_4XX_Count', prefix: '4xx' },
    { metric: 'HTTPCode_ELB_5XX_Count', prefix: '5xx' },
  ])) + p.steps + p.legend('table'),

  p.timeseries(6, 'Target Response Counts by Code', { h: 11, w: 12, x: 12, y: 11 }, targets(s, [
    { metric: 'HTTPCode_Target_2XX_Count', prefix: '2xx' },
    { metric: 'HTTPCode_Target_3XX_Count', prefix: '3xx' },
    { metric: 'HTTPCode_Target_4XX_Count', prefix: '4xx' },
    { metric: 'HTTPCode_Target_5XX_Count', prefix: '5xx' },
  ])) + p.steps + p.legend('table'),

  p.timeseries(7, 'Request Count', { h: 11, w: 12, x: 0, y: 22 }, targets(s, [
    { metric: 'RequestCount', prefix: 'Requests' },
    { metric: 'GrpcRequestCount', prefix: 'GrpcRequests' },
    { metric: 'IPv6RequestCount', prefix: 'IPv6Requests' },
  ])) + p.steps + p.legend(),

  p.timeseries(8, 'Request Count per Target', { h: 11, w: 12, x: 12, y: 22 }, targets(s, [
    { metric: 'RequestCountPerTarget', prefix: null },
  ])) + p.steps + p.legend(),

  p.timeseries(9, 'Connection Count', { h: 11, w: 12, x: 0, y: 33 }, targets(s, [
    { metric: 'ActiveConnectionCount', prefix: 'ActiveConnections' },
    { metric: 'NewConnectionCount', prefix: 'NewConnections' },
  ])) + p.legend(),

  p.timeseries(10, 'Processed Bytes', { h: 11, w: 12, x: 12, y: 33 }, targets(s, [
    { metric: 'ProcessedBytes', prefix: 'ProcessedBytes' },
  ]), unit='bytes') + p.bars() + p.legend(),

  p.timeseries(11, 'TargetResponseTime', { h: 11, w: 12, x: 0, y: 44 }, targets(s, [
    { metric: 'TargetResponseTime', prefix: null },
  ]), unit='s') + p.legend(),

  p.timeseries(12, 'HTTP_Fixed_Response_Count', { h: 11, w: 12, x: 12, y: 44 }, targets(s, [
    { metric: 'HTTP_Fixed_Response_Count', prefix: null },
  ])) + p.bars(stacked=false) + p.legend(),

  p.timeseries(13, 'ELB 5xx Responses by Code', { h: 12, w: 24, x: 0, y: 55 }, targets(s, [
    { metric: 'HTTPCode_ELB_500_Count', prefix: '500s' },
    { metric: 'HTTPCode_ELB_502_Count', prefix: '502s' },
    { metric: 'HTTPCode_ELB_503_Count', prefix: '503s' },
    { metric: 'HTTPCode_ELB_504_Count', prefix: '504s' },
  ])) + p.steps + p.legend('table'),
];

// Every metric the panels query, for requires(). Kept next to the panel list
// above; test_requires_covers_every_queried_metric holds the two together.
local metricNames = [
  'HealthyHostCount',
  'AnomalousHostCount',
  'UnHealthyHostCount',
  'MitigatedHostCount',
  'HealthyStateDNS',
  'UnhealthyStateDNS',
  'PeakLCUs',
  'RuleEvaluations',
  'HTTPCode_ELB_3XX_Count',
  'HTTPCode_ELB_4XX_Count',
  'HTTPCode_ELB_5XX_Count',
  'HTTPCode_Target_2XX_Count',
  'HTTPCode_Target_3XX_Count',
  'HTTPCode_Target_4XX_Count',
  'HTTPCode_Target_5XX_Count',
  'RequestCount',
  'GrpcRequestCount',
  'IPv6RequestCount',
  'RequestCountPerTarget',
  'ActiveConnectionCount',
  'NewConnectionCount',
  'ProcessedBytes',
  'TargetResponseTime',
  'HTTP_Fixed_Response_Count',
  'HTTPCode_ELB_500_Count',
  'HTTPCode_ELB_502_Count',
  'HTTPCode_ELB_503_Count',
  'HTTPCode_ELB_504_Count',
];

{
  name: 'aws-elb',

  // Declared so an integrator can diff against their recorded metrics BEFORE
  // rendering — a load balancer type that never emits some of these (Grpc on
  // a plain HTTP listener, say) shows up here, not as an empty panel later.
  requires():: { metrics: [metric(n) for n in metricNames] },

  dashboards():: [{
    name: 'aws-elb',
    kind: 'dashboard',
    title: 'AWS ELB',
    modes: ['scoped', 'browse'],

    build(ctx)::
      local s = ctx.scope;
      p.dashboard(
        title=self.title,
        tags=['aws', 'elb'],
        variables=s.variables
                  + [cw.dimVariable(s, 'loadBalancer', 'Load Balancer', lbDim,
                                    metric('RequestCount'))],
        panels=panels(s),
      ),
  }],

  alerts():: [],
}
