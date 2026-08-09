// SQL query builders for the Scout datasource.
//
// Build every query here rather than hand-writing SQL in a template, for one
// reason above all others: attribute placement is not uniform, and getting it
// wrong produces NO ERROR — just an empty result. On a dashboard that is a
// blank panel someone eventually notices; on an alert rule it is a rule that
// never fires.
//
//   ResourceAttributes  where telemetry came from: container.name, environment,
//                       tenant, host.*, k8s.*
//   Attributes          datapoint dimensions: status, handler, method, version
//
// Which map a given key lives in varies per metric, so it cannot be inferred
// from the name alone. Validate generated queries against a per-metric dump of
// the keys each metric actually carries, and fail the build when a dimension is
// read from the wrong map.
{
  local ch = self,

  tables:: {
    gauge: 'otel_metrics_gauge',
    sum: 'otel_metrics_sum',
    summary: 'otel_metrics_summary',
    histogram: 'otel_metrics_histogram',
    logs: 'otel_logs',
    traces: 'otel_traces',
  },

  // Fixes the $timeSeries/$rate bucket width instead of letting the plugin pick
  // from panel width. Matches the metrics' scrape cadence and stops windowed
  // derivations emptying out at short time ranges.
  defaultStep:: '1m',

  // defaultStep in seconds. counterRateQuery divides by this to turn a
  // per-bucket delta into a per-second rate, so the two must agree — deriving
  // the divisor from the bucket timestamps instead would be more general but
  // reads a different unit depending on how $timeSeries is bound.
  defaultStepSeconds:: 60,

  // ---- attribute accessors -------------------------------------------------

  resAttr(name):: "ResourceAttributes['" + name + "']",
  attr(name):: "Attributes['" + name + "']",

  // Dimensions that live in ResourceAttributes. Anything else is treated as a
  // datapoint Attribute. Five keys (environment, tenant, host, url.scheme,
  // server.port) are ambiguous across the full metric set — resource on some
  // metrics, attribute on others — which is exactly why the per-metric test
  // exists rather than trusting this table alone.
  resourceDims:: [
    'environment',
    'tenant',
    'container.name',
    'service.name',
    'service.instance.id',
    'host.name',
    'host.id',
    'host.type',
    'ec2.tag.Name',
    'k8s.pod.name',
    'k8s.namespace.name',
    'k8s.node.name',
    'deployment.environment',
    'cloud.region',
    'cloud.availability_zone',
  ],

  dim(name):: if std.member(ch.resourceDims, name) then ch.resAttr(name) else ch.attr(name),

  // ---- the environment label grammar, in SQL --------------------------------
  //
  // Must agree with the identity profile's parseLabel: split on the FIRST
  // hyphen, so `stg-big-corp` yields prefix `stg`, tenant `big-corp`.
  // splitByChar would give `big`.
  //
  // Only ever used in variable queries and SELECT lists, never in a panel's
  // WHERE — position()/substring() on a map value defeats the bloom-filter index.
  local envCol = "ResourceAttributes['environment']",

  envPrefixExpr::
    "if(position(%(c)s, '-') = 0, %(c)s, substring(%(c)s, 1, position(%(c)s, '-') - 1))" % { c: envCol },

  envTenantExpr::
    "if(position(%(c)s, '-') = 0, '', substring(%(c)s, position(%(c)s, '-') + 1))" % { c: envCol },

  // ---- predicates ----------------------------------------------------------

  // Table reference, qualified by the instance's database. Not `$table`: the
  // database differs between production and non-production deployments, so
  // it is bound at render time.
  from(database, table):: 'FROM ' + database + '.' + table,

  // Predicate order is load-bearing. The metric tables are sorted by
  // (ServiceName, MetricName, Attributes, TimeUnix), so ServiceName comes first,
  // then MetricName, then any map filter. Filtering a map without ServiceName
  // means the primary index never narrows — a full scan.
  metricPredicates(metric, serviceName=null)::
    std.prune([
      if serviceName != null then "ServiceName = '" + serviceName + "'" else null,
      "MetricName = '" + metric + "'",
      ch.recorded,
    ]),

  // OTel's FLAG_NO_RECORDED_VALUE (Flags bit 0). A datapoint carrying it means
  // "nothing was recorded in this interval" — but ClickHouse stores it with
  // Value = 0.0, indistinguishable from a real zero unless you check the flag.
  //
  // Excluded from every metric query, because including it is wrong in a way
  // that looks plausible. A gauge sampled only when a periodic check runs emits
  // one of these in between, so a latency panel draws a sawtooth alternating
  // between the true value and zero — which reads as two overlaid series. On a
  // max() it merely adds noise; on an avg() it drags the line toward zero.
  //
  // Tested as a bitmask, not `Flags = 0`, so a datapoint carrying some other
  // flag alongside is still counted.
  recorded:: 'bitAnd(Flags, 1) = 0',

  // Exact equality on the environment label — index-friendly, and what `scoped`
  // assets use.
  envEquals(envLabel):: envCol + " = '" + envLabel + "'",

  // Variable-driven membership, for `browse`. `${var:singlequote}` quotes each
  // value; a bare `IN ($var)` would not.
  //
  // Deliberately NOT wrapped in $conditionalTest: that helper drops the predicate
  // when the variable is empty, which here would show every tenant's data instead
  // of none. An empty selection must yield no rows.
  envIn(varName):: envCol + ' IN (${' + varName + ':singlequote})',

  // ---- attribute tenancy: bare tier + a separate `tenant` resource attribute -
  //
  // Some stacks do not fold the tenant into the environment label. They tag
  // `environment` with the bare tier (`stg`, `prod`) and carry the tenant
  // separately as ResourceAttributes['tenant']. The identity profile decides
  // which convention applies and calls these instead of envEquals/envIn — see
  // identity/scopes.libsonnet for why that is declared rather than inferred.
  resTenant:: ch.resAttr('tenant'),

  // Pinned equality for `scoped` + `attribute` tenancy — both the bare tier and
  // the tenant must match, or a tenant's scoped dashboard would show every
  // tenant sharing its environment.
  envAttrEquals(environment, tenant)::
    envCol + " = '" + environment + "' AND " + ch.resTenant + " = '" + tenant + "'",

  // Variable-driven membership for `browse` + `attribute` tenancy. Two
  // independent IN clauses: unlike the label grammar, environment and tenant are
  // not the same value chained through one dropdown, so each variable filters
  // its own column.
  envAttrIn(envVar, tenantVar)::
    envCol + ' IN (${' + envVar + ':singlequote}) AND '
    + ch.resTenant + ' IN (${' + tenantVar + ':singlequote})',

  // Multi-dimensional alerts group by the label and carry it out as a column, so
  // it becomes an alert label for routing.
  envSelect:: envCol + ' AS environment',

  // The browse series key under `attribute` tenancy. There `environment` is the
  // bare tier, so splitting on it would collapse every selected tenant into one
  // line per tier — the opposite of what a browse dashboard is for.
  tenantSelect:: "ResourceAttributes['tenant'] AS tenant",

  where(clauses):: 'WHERE ' + std.join('\n  AND ', std.prune(clauses)),

  atQuantile(q):: 'arrayElement(ValueAtQuantiles.Value, indexOf(ValueAtQuantiles.Quantile, ' + q + '))',

  // ---- query shapes --------------------------------------------------------

  // A time series over one metric. $timeSeries must always be paired with
  // GROUP BY t.
  timeSeriesQuery(database, table, metric, valueExpr, alias, predicates, groupBy=[]):: std.join('\n', [
    'SELECT $timeSeries AS t, ' + valueExpr + ' AS ' + alias
    + (if std.length(groupBy) > 0 then ', ' + std.join(', ', groupBy) else ''),
    ch.from(database, table),
    ch.where(['$timeFilter'] + predicates),
    'GROUP BY t' + (if std.length(groupBy) > 0 then ', ' + std.join(', ', [ch.aliasOf(g) for g in groupBy]) else ''),
    'ORDER BY t',
  ]) + '\n',

  // Per-bucket, per-series increase of a cumulative counter, computed in SQL.
  //
  // NOT $increase/$increaseColumns. Those are plugin macros expanded in Grafana,
  // and the datasource proxy passes SQL through unchanged, so their expansion is
  // invisible from here — we cannot test what they actually do. Measured against
  // a real panel, $increaseColumns draws a monotonically RISING line for a
  // cumulative counter, i.e. a running total rather than a per-interval count.
  // For a counter that advances a handful of times an hour, the panel should be
  // mostly zero with occasional small increments, not a smooth ramp.
  //
  // Three details carry the correctness:
  //   1. The delta is per INSTANCE, taken before summing across the series key.
  //      Differencing an already-summed series lets one container restarting
  //      corrupt the total into a plausible-looking line.
  //   2. `rn > 1` drops each series' first bucket. lagInFrame returns 0 there,
  //      so the first delta would otherwise be the counter's whole lifetime
  //      total — a spike at the left edge of every panel.
  //   3. greatest(..., 0) clamps the negative delta a counter reset produces.
  //      A restart should read as a gap, not as a negative count.
  // The same delta as a per-second rate. Divides by the pinned bucket width
  // rather than by the gap between bucket timestamps, because `t` carries a
  // different unit depending on how $timeSeries is bound and a silently wrong
  // scale factor is worse than an explicit constant. See defaultStepSeconds.
  counterRateQuery(database, table, keyExpr, alias, predicates, valueCol='Value')::
    ch.counterDeltaQuery(database,
                         table,
                         keyExpr,
                         alias,
                         predicates,
                         divisor=ch.defaultStepSeconds,
                         valueCol=valueCol),

  // The delta accumulated from the start of the selected range — a rising line,
  // which is what the SignalFx "Count" charts show and what an operator reading
  // "how many succeeded today" expects.
  //
  // NOT the raw cumulative Value. The difference matters: raw Value is the counter's lifetime total, so it
  // ignores the time picker, and a process restart drops it to zero mid-chart.
  // This accumulates per-bucket deltas instead, so it starts at zero for the
  // window being viewed and a restart is absorbed by the greatest(...,0) clamp.
  counterTotalQuery(database, table, keyExpr, alias, predicates, valueCol='Value'):: std.join('\n', [
    'SELECT t, series,',
    '  sum(per_bucket) OVER (PARTITION BY series ORDER BY t',
    '                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS ' + alias,
    'FROM (',
    ch.indent(ch.counterDeltaQuery(database, table, keyExpr, 'per_bucket', predicates, valueCol=valueCol)),
    ')',
    'ORDER BY t',
  ]) + '\n',

  // Indent a nested query one level. The filter drops the trailing empty line
  // every builder's terminating newline produces; none of them emit a blank
  // line internally.
  indent(sql):: std.join('\n', [
    '  ' + line
    for line in std.filter(function(l) l != '', std.split(sql, '\n'))
  ]),

  // `valueCol` names the cumulative column to difference. It defaults to `Value`,
  // which is what otel_metrics_sum and otel_metrics_gauge carry — but
  // otel_metrics_summary has NO Value column at all, only Count and Sum. A
  // summary's Count is itself a cumulative counter, so "requests per second" over
  // one is this builder with valueCol='Count'; leaving it at the default renders
  // SQL referencing a column that does not exist.
  counterDeltaQuery(database, table, keyExpr, alias, predicates, divisor=null, valueCol='Value'):: std.join('\n', [
    'SELECT t, series, sum(d)'
    + (if divisor != null then ' / ' + divisor else '')
    + ' AS ' + alias,
    'FROM (',
    '  SELECT t, series, greatest(v - prev, 0) AS d',
    '  FROM (',
    '    SELECT t, series, instance, v,',
    '      lagInFrame(v) OVER (PARTITION BY series, instance ORDER BY t) AS prev,',
    '      row_number() OVER (PARTITION BY series, instance ORDER BY t) AS rn',
    '    FROM (',
    '      SELECT $timeSeries AS t,',
    '        ' + keyExpr + ' AS series,',
    "        ResourceAttributes['service.instance.id'] AS instance,",
    '        anyLast(' + valueCol + ') AS v',
    '      ' + ch.from(database, table),
    '      ' + ch.where(['$timeFilter'] + predicates),
    '      GROUP BY t, series, instance',
    '      ORDER BY t',
    '    )',
    '  )',
    '  WHERE rn > 1',
    ')',
    'GROUP BY t, series',
    'ORDER BY t',
  ]) + '\n',

  // ---- counter query shapes -------------------------------------------------
  //
  // $perSecond, $increase and the *Columns variants REPLACE the SELECT…FROM
  // head — they must lead the query. Passed as timeSeriesQuery's valueExpr they
  // render as `SELECT $timeSeries AS t, $perSecond(Value) AS x`, which is valid
  // SQL that returns nothing. That is why these do not reuse timeSeriesQuery.
  counterQuery(database, table, macro, predicates):: std.join('\n', [
    macro,
    ch.from(database, table),
    ch.where(['$timeFilter'] + predicates),
  ]) + '\n',

  perSecondQuery(database, table, predicates, col='Value')::
    ch.counterQuery(database, table, '$perSecond(' + col + ')', predicates),

  increaseQuery(database, table, predicates, col='Value')::
    ch.counterQuery(database, table, '$increase(' + col + ')', predicates),

  // The *Columns macros take exactly ONE key expression, so a panel splitting on
  // two dimensions folds them with seriesKey().
  perSecondColumnsQuery(database, table, keyExpr, predicates, col='Value')::
    ch.counterQuery(database,
                    table,
                    '$perSecondColumns(' + keyExpr + ' AS series, ' + col + ')',
                    predicates),

  increaseColumnsQuery(database, table, keyExpr, predicates, col='Value')::
    ch.counterQuery(database,
                    table,
                    '$increaseColumns(' + keyExpr + ' AS series, ' + col + ')',
                    predicates),

  // One series per distinct combination. The separator is display-only.
  seriesKey(dims)::
    if std.length(dims) == 1 then dims[0]
    else 'concat(' + std.join(", ' / ', ", dims) + ')',

  // $columns injects its own time filter, so this one omits $timeFilter — adding
  // it duplicates the predicate. For non-counter breakdowns such as count().
  columnsQuery(database, table, keyExpr, aggExpr, predicates):: std.join('\n', [
    '$columns(' + keyExpr + ' AS series, ' + aggExpr + ')',
    ch.from(database, table),
    ch.where(predicates),
    'GROUP BY t, series',
    'ORDER BY t',
  ]) + '\n',

  // A windowed mean over a summary's cumulative Sum and Count.
  //
  // Not expressible with macros: $rate(sum(Sum)) / $rate(sum(Count)) would need
  // two macros in one query. Two constraints shape the SQL:
  //
  //   1. The delta is taken PER INSTANCE, before aggregating. Differencing an
  //      already-summed series mixes unrelated counters, and one container
  //      restarting corrupts the ratio into a line that still looks plausible.
  //   2. It lags across buckets rather than using max-min within one. At a
  //      1-minute scrape and defaultStep 1m there is a single sample per
  //      instance per bucket, so max-min is always zero.
  //
  // d_count > 0 discards the negative delta a counter reset produces. A gap
  // reads as missing data; a negative average reads as a real measurement.
  summaryAverageQuery(database, table, keyExpr, alias, predicates):: std.join('\n', [
    'SELECT t, series, sum(d_sum) / sum(d_count) AS ' + alias,
    'FROM (',
    '  SELECT t, series, instance,',
    '    s - lagInFrame(s) OVER (PARTITION BY series, instance ORDER BY t) AS d_sum,',
    '    c - lagInFrame(c) OVER (PARTITION BY series, instance ORDER BY t) AS d_count',
    '  FROM (',
    '    SELECT $timeSeries AS t,',
    '      ' + keyExpr + ' AS series,',
    "      ResourceAttributes['service.instance.id'] AS instance,",
    '      anyLast(Sum) AS s,',
    '      anyLast(Count) AS c',
    '    ' + ch.from(database, table),
    '    ' + ch.where(['$timeFilter'] + predicates),
    '    GROUP BY t, series, instance',
    '    ORDER BY t',
    '  )',
    ')',
    'WHERE d_count > 0',
    'GROUP BY t, series',
    'ORDER BY t',
  ]) + '\n',

  // An instant (non-time-series) aggregate, which is what an alert rule reduces.
  instantQuery(database, table, valueExpr, alias, predicates, groupBy=[]):: std.join('\n', [
    'SELECT ' + valueExpr + ' AS ' + alias
    + (if std.length(groupBy) > 0 then ', ' + std.join(', ', groupBy) else ''),
    ch.from(database, table),
    ch.where(['$timeFilter'] + predicates),
  ] + (
    if std.length(groupBy) > 0 then ['GROUP BY ' + std.join(', ', [ch.aliasOf(g) for g in groupBy])] else []
  )) + '\n',

  // `expr AS alias` -> `alias`, for reuse in GROUP BY.
  aliasOf(sel)::
    local hits = std.findSubstr(' AS ', sel);
    if std.length(hits) == 0 then sel else sel[hits[std.length(hits) - 1] + 4:],

  // Template-variable queries. A short fixed window rather than $timeFilter, so
  // dropdowns load fast regardless of the dashboard's range, and always narrowed
  // by ServiceName/MetricName so they prune on the primary index.
  variableWindow:: 'TimeUnix > now() - INTERVAL 1 HOUR',
}
