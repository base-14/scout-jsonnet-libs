// CloudWatch metric-stream access.
//
// AWS telemetry arrives through a CloudWatch metric stream, and the collector
// writes each period's statistic set to otel_metrics_summary — so the current
// value of a stream metric is the bucket's Sum, not a cumulative counter, and
// the counter-delta machinery in sql.libsonnet does not apply.
//
// The stream flattens CloudWatch dimensions into ONE datapoint attribute:
// Attributes['Dimensions'] holds a JSON object such as
// {"LoadBalancer":"app/my-lb/123"}. That is the third attribute-placement trap
// after resource-vs-datapoint: reading Attributes['LoadBalancer'] is valid SQL
// that returns empty. Dimension access therefore goes through dim(), the same
// way sql.libsonnet routes plain attributes through dim()/attr().
local manifest = import 'manifest.libsonnet';
local p = import 'panels.libsonnet';
local ch = import 'sql.libsonnet';

{
  local cw = self,

  // The collector service that ingests the stream. ServiceName leads every
  // predicate list (see sql.libsonnet on predicate order), so stream queries
  // prune on it before touching the metric name.
  streamServiceName:: 'aws-cloudwatch-stream',

  // How this deployment's collector tags stream metrics. The scope may carry
  // `cloudwatchService`: a literal ServiceName, or the reserved word
  // 'namespace' meaning the metric's own namespace —
  // amazonaws.com/AWS/RDS/CPUUtilization -> 'AWS/RDS'. Absent, the default
  // collector name above stands. Carried on the scope rather than configured
  // here so mixins need no per-deployment edits.
  serviceNameFor(s, metric)::
    local declared = std.get(s, 'cloudwatchService', cw.streamServiceName);
    if declared == 'namespace'
    then std.join('/', std.split(metric, '/')[1:3])
    else declared,

  // Stream metric names are prefixed with the provider and namespace:
  // amazonaws.com/AWS/ApplicationELB/RequestCount.
  metricName(namespace, metric):: 'amazonaws.com/' + namespace + '/' + metric,

  // simpleJSONExtractString rather than JSONExtractString: the Dimensions
  // object is flat with string values, which is exactly the shape the simple
  // (non-parsing, much faster) variant supports.
  dim(name):: "simpleJSONExtractString(Attributes['Dimensions'], '" + name + "')",

  // Datapoints exist per dimension SET — RequestCount is streamed once per
  // {LoadBalancer} and again per {LoadBalancer,TargetGroup,...}. Use this to
  // pin a query to the dimension set it means to read.
  hasDim(name):: "JSONHas(Attributes['Dimensions'], '" + name + "')",

  // Variable-driven membership over a dimension. Deliberately NOT
  // $conditionalTest, same stance as ch.envIn: dropping the predicate on an
  // empty selection would show every value instead of none, and "All" expands
  // to explicit values so plain IN also serves includeAll.
  dimIn(name, varName):: cw.dim(name) + ' IN (${' + varName + ':singlequote})',

  // One series per dimension value, prefixed when a panel overlays several
  // metrics. null keeps the bare value for single-metric panels.
  series(name, prefix=null)::
    if prefix == null then cw.dim(name)
    else "concat('" + prefix + " - ', " + cw.dim(name) + ')',

  // A panel target over one stream metric, split per keyExpr. The stream
  // writes each period's statistic set to the summary table (see the header),
  // so valueExpr aggregates Sum — 'max(Sum)'/'avg(Sum)' — never a counter
  // delta. `s` is a scope from identity/scopes.libsonnet: it supplies the
  // instance binding and, crucially, the environment predicate, which is how
  // a mixin using this stays inside layering rule 3.
  streamTarget(s, refId, metric, valueExpr, keyExpr, extraPredicates=[])::
    p.target(
      s.datasourceUid,
      s.database,
      ch.tables.summary,
      ch.timeSeriesQuery(
        s.database,
        ch.tables.summary,
        metric,
        valueExpr,
        'value',
        ch.metricPredicates(metric, cw.serviceNameFor(s, metric))
        + [s.envPredicate]
        + extraPredicates,
        groupBy=[keyExpr + ' AS series'],
      ),
      refId=refId,
    ),

  // A dropdown over a dimension's values, appended to the scope's own
  // variables by the mixin. s.envPredicate keeps the option list inside the
  // scope in every mode: under browse it chains off the env dropdown, under
  // scoped it is pinned — a data axis within the environment, so it survives
  // pinning. hasDim keeps '' out of the options: the probe metric is also
  // streamed for dimension sets that lack this key, and a missing key
  // extracts as the empty string.
  dimVariable(s, varName, label, dimName, probeMetric):: {
    name: varName,
    label: label,
    type: 'query',
    multi: true,
    includeAll: true,
    // No custom allValue: `*` would break the IN clause. "All" must expand
    // to explicit values.
    allValue: null,
    refresh: 1,
    datasource: { type: manifest.datasourceType, uid: s.datasourceUid },
    query: std.join('\n', [
      'SELECT DISTINCT ' + cw.dim(dimName) + ' AS ' + varName,
      ch.from(s.database, ch.tables.summary),
      ch.where(
        [ch.variableWindow]
        + ch.metricPredicates(probeMetric, cw.serviceNameFor(s, probeMetric))
        + [cw.hasDim(dimName), s.envPredicate]
      ),
      'ORDER BY ' + varName,
    ]) + '\n',
    current: {},
    options: [],
    hide: 0,
  },
}
