// Alert rule construction.
//
// ============================================================================
// UNVERIFIED SHAPE — spike item 1. Read this before changing anything below.
//
// The authoring schema for alert rules is not yet confirmed. The CLI's alert
// commands are READ-ONLY (get/list/status), and the AlertRule schema the server
// advertises requires `state`, `health`, `lastEvaluation`, and `evaluationTime`
// — runtime status fields, not authoring fields. That schema is read-shaped.
//
// What is implemented here is the established unified-alerting provisioning shape
// (title / condition / data[] / noDataState / execErrState / for / labels /
// annotations) for the same objects.
//
// The whole shape is confined to `rule()` and `group()` below. Correcting it
// after the spike is a change to these two functions and nothing else — no
// template, no check, and no pipeline stage reaches into a rule's internals.
// ============================================================================
local manifest = import 'manifest.libsonnet';

{
  local a = self,

  // Rule stages: A is the query, B reduces it to a single value, C compares.
  // Splitting reduce from threshold is what makes a rule's condition legible in
  // the UI and editable without rewriting the SQL.
  queryRefId:: 'A',
  reduceRefId:: 'B',
  thresholdRefId:: 'C',

  // A rule's query stage. `relativeTimeRange` is the window the query sees.
  queryStage(datasourceUid, database, table, sql, windowSeconds=600):: {
    refId: a.queryRefId,
    datasourceUid: datasourceUid,
    relativeTimeRange: { from: windowSeconds, to: 0 },
    model: {
      refId: a.queryRefId,
      datasource: { type: manifest.datasourceType, uid: datasourceUid },
      database: database,
      table: table,
      query: sql,
      format: 'table',
      dateTimeColDataType: 'TimeUnix',
      dateTimeType: 'DATETIME64',
      editorMode: 'sql',
      intervalFactor: 1,
      round: '0s',
      skip_comments: true,
    },
  },

  reduceStage(reducer='last'):: {
    refId: a.reduceRefId,
    datasourceUid: manifest.expressionDatasourceUid,
    relativeTimeRange: { from: 0, to: 0 },
    model: {
      refId: a.reduceRefId,
      type: 'reduce',
      datasource: { type: manifest.expressionDatasourceUid, uid: manifest.expressionDatasourceUid },
      expression: a.queryRefId,
      reducer: reducer,
      settings: { mode: 'dropNN' },
    },
  },

  // `op` is 'gt' or 'lt'.
  // `threshold` is one number for gt/lt, or [low, high] for the range
  // evaluators (within_range / outside_range) — Grafana's evaluator params
  // are a list either way. Banded severities (minor 1-5, major 5-10,
  // critical >=10) are three rules whose ranges cannot overlap-fire.
  thresholdStage(threshold, op='gt'):: {
    refId: a.thresholdRefId,
    datasourceUid: manifest.expressionDatasourceUid,
    relativeTimeRange: { from: 0, to: 0 },
    model: {
      refId: a.thresholdRefId,
      type: 'threshold',
      datasource: { type: manifest.expressionDatasourceUid, uid: manifest.expressionDatasourceUid },
      expression: a.reduceRefId,
      conditions: [{
        evaluator: { type: op, params: if std.isArray(threshold) then threshold else [threshold] },
        operator: { type: 'and' },
        query: { params: [a.reduceRefId] },
        reducer: { type: 'last', params: [] },
        type: 'query',
      }],
    },
  },

  // One rule.
  //
  // noDataState is deliberately `NoData` rather than `OK`: a query returning
  // nothing is a broken rule, not a healthy one, and it should be visible as such
  // rather than silently reading as fine. `make dev-verify` and `make smoke` both
  // treat NoData as a failure.
  rule(uid, title, folderUid, datasourceUid, database, table, sql, threshold, opts={})::
    local o = {
      op: 'gt',
      reducer: 'last',
      windowSeconds: 600,
      forSeconds: 300,
      labels: {},
      annotations: {},
      contactPoint: null,
      groupBy: [],
    } + opts;
    {
      uid: uid,
      title: title,
      folderUID: folderUid,
      condition: a.thresholdRefId,
      data: [
        a.queryStage(datasourceUid, database, table, sql, o.windowSeconds),
        a.reduceStage(o.reducer),
        a.thresholdStage(threshold, o.op),
      ],
      noDataState: 'NoData',
      execErrState: 'Error',
      'for': a.duration(o.forSeconds),
      labels: o.labels,
      annotations: o.annotations,
      isPaused: false,
    } + (
      if o.contactPoint != null then { notificationSettings: { receiver: o.contactPoint } } else {}
    ),

  // A rule group. `interval` is seconds; each rule's `for` must be a multiple of
  // it, which lint checks.
  group(name, folderUid, intervalSeconds, rules):: {
    title: name,
    folderUid: folderUid,
    interval: intervalSeconds,
    rules: rules,
  },

  duration(seconds)::
    if seconds % 3600 == 0 && seconds >= 3600 then '%dh' % (seconds / 3600)
    else if seconds % 60 == 0 then '%dm' % (seconds / 60)
    else '%ds' % seconds,

  // ---- multi-dimensional rules ---------------------------------------------
  //
  // The `browse` equivalent for alerts: one rule per database scope, grouping by
  // `environment`, firing one alert instance per label set. The grouped column
  // becomes an alert label, so the notification policy can route per tenant.
  //
  // Instances that override a threshold are EXCLUDED here and render their own
  // scoped rule instead. Without the exclusion a tenant is covered twice — once
  // at the default threshold, once by its own — and pages twice for one incident.
  // The list is derived from what actually rendered scoped, so it cannot drift.
  excludeClause(excludedLabels)::
    if std.length(excludedLabels) == 0 then null
    else "ResourceAttributes['environment'] NOT IN ("
         + std.join(', ', ["'" + l + "'" for l in std.sort(excludedLabels)]) + ')',
}
