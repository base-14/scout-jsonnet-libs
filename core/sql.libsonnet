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
    // A pre-aggregated span rollup, not part of the raw OTel schema. See the
    // APM section at the foot of this file before using it.
    apmTraces: 'otel_traces_apm',
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
    // The ECS docker-stats dimension. A RESOURCE key, unlike its neighbours
    // ecs_task_group and container_id which are datapoint attributes on the very
    // same metrics — exactly the split a per-metric attribute test exists to
    // police, so it must be listed here rather than left to the default.
    'container_spec_name',
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
  // NOT $increase/$increaseColumns. Those are plugin macros expanded inside Scout,
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

  // A time-series aggregate for MULTI-DIMENSIONAL alert rules.
  //
  // Grafana's expression engine ingests alert query responses as wide time
  // series; a label-bearing TABLE response is a frame it cannot type
  // ("[sse.readDataError] input data must be a wide series but got type not",
  // measured 2026-08-31 — intermittently, since some responses happened to
  // convert). So a rule with a group-by axis queries buckets: the plugin
  // turns (t, label, value) rows into one series per label, reduce acts per
  // series, and the rule fires one alert instance per label set.
  //
  // Buckets are hand-rolled at a FIXED width, not $timeSeries: the macro's
  // width comes from the panel/alert context and an alert must not change
  // meaning with it. This trades SignalFx's sliding windows for fixed ones —
  // pair it with a rule window of 2x the bucket and a `max` reducer so a
  // threshold crossing is seen whichever bucket boundary it straddles.
  alertBucketMs(seconds):: 'toUnixTimestamp(intDiv(toUInt32(TimeUnix), %(s)d) * %(s)d) * 1000' % { s: seconds },

  alertSeriesQuery(database, table, valueExpr, alias, predicates, groupBy=[], bucketSeconds=300):: std.join('\n', [
    'SELECT ' + ch.alertBucketMs(bucketSeconds) + ' AS t'
    + (if std.length(groupBy) > 0 then ', ' + std.join(', ', groupBy) else '')
    + ', ' + valueExpr + ' AS ' + alias,
    ch.from(database, table),
    ch.where(['$timeFilter'] + predicates),
    'GROUP BY t' + (if std.length(groupBy) > 0 then ', ' + std.join(', ', [ch.aliasOf(g) for g in groupBy]) else ''),
    'ORDER BY t',
  ]) + '\n',

  // The counter equivalent of alertSeriesQuery: per-bucket INCREASE of a
  // cumulative counter, grouped by label columns, as wide time series.
  //
  // Same correctness rules as counterDeltaQuery, which this adapts to the
  // alert shape: the delta is taken per service instance BEFORE summing
  // across the label set (a restarting container must not corrupt the
  // total), each instance's first bucket is dropped (its lag is the
  // counter's lifetime), and resets clamp to zero. Labels are separate
  // columns — the datasource carries string columns through as frame
  // labels, so each label set becomes one alert instance.
  alertCounterSeriesQuery(database, table, labelCols, alias, predicates, bucketSeconds=300):: std.join('\n', [
    'SELECT t' + std.join('', [', ' + ch.aliasOf(l) for l in labelCols]) + ', sum(d) AS ' + alias,
    'FROM (',
    '  SELECT t' + std.join('', [', ' + ch.aliasOf(l) for l in labelCols]) + ', instance,',
    '    greatest(v - lagInFrame(v) OVER (PARTITION BY '
    + std.join(', ', [ch.aliasOf(l) for l in labelCols])
    + ', instance ORDER BY t), 0) AS d,',
    '    row_number() OVER (PARTITION BY '
    + std.join(', ', [ch.aliasOf(l) for l in labelCols])
    + ', instance ORDER BY t) AS rn',
    '  FROM (',
    '    SELECT ' + ch.alertBucketMs(bucketSeconds) + ' AS t,',
    '      ' + std.join(',\n      ', labelCols) + ',',
    "      ResourceAttributes['service.instance.id'] AS instance,",
    '      anyLast(Value) AS v',
    '    ' + ch.from(database, table),
    '    ' + ch.where(['$timeFilter'] + predicates),
    '    GROUP BY t' + std.join('', [', ' + ch.aliasOf(l) for l in labelCols]) + ', instance',
    '  )',
    ')',
    'WHERE rn > 1',
    'GROUP BY t' + std.join('', [', ' + ch.aliasOf(l) for l in labelCols]),
    'ORDER BY t',
  ]) + '\n',

  // An instant (non-time-series) aggregate, which is what an alert rule reduces.
  // The UNION ALL sentinel keeps the response non-empty: a zero-row table
  // from this datasource is a frame Grafana's expression engine cannot type
  // ("[sse.readDataError] input data must be a wide series but got type not",
  // measured 2026-08-31), so a count-style alert whose window is quiet flaps
  // to health=error instead of evaluating a clean zero. The sentinel is one
  // baseline instance per rule — value 0, labels '__none__' — which can never
  // cross a threshold.
  instantQuery(database, table, valueExpr, alias, predicates, groupBy=[]):: std.join('\n', [
    'SELECT ' + valueExpr + ' AS ' + alias
    + (if std.length(groupBy) > 0 then ', ' + std.join(', ', groupBy) else ''),
    ch.from(database, table),
    ch.where(['$timeFilter'] + predicates),
  ] + (
    if std.length(groupBy) > 0 then ['GROUP BY ' + std.join(', ', [ch.aliasOf(g) for g in groupBy])] else []
  ) + [
    'UNION ALL SELECT 0'
    + std.join('', [", '__none__'" for g in groupBy]),
  ]) + '\n',

  // Freshness as a wide TIME SERIES: seconds since the last datapoint per
  // label set, stamped on a single "now" bucket. The table-format variant
  // (instantQuery) breaks the SSE reader once more than one string column
  // rides along — time_series carries any number of label columns as frame
  // labels, so absence detectors with multi-part identity use this form.
  // The sentinel series pins the frame when nothing matches; its lag of 0
  // never crosses a gt threshold.
  freshnessSeriesQuery(database, table, predicates, groupBy=[], alias='lag_seconds')::
    if std.length(groupBy) == 0 then
      // Ungrouped: a plain aggregate always returns exactly ONE row, even
      // over zero input rows — so no sentinel is needed (a sentinel here
      // would duplicate the series' empty label set, which the rule engine
      // rejects). max() over nothing is NULL; coalescing to epoch turns
      // total silence into a huge lag, which is the correct alarm.
      std.join('\n', [
        'SELECT toUnixTimestamp(toStartOfMinute(now())) * 1000 AS t'
        + ", dateDiff('second', coalesce(max(TimeUnix), toDateTime64(0, 9)), now()) AS " + alias,
        ch.from(database, table),
        ch.where(['$timeFilter'] + predicates),
      ]) + '\n'
    else std.join('\n', [
      'SELECT toUnixTimestamp(toStartOfMinute(now())) * 1000 AS t'
      + ', ' + std.join(', ', groupBy)
      + ", dateDiff('second', max(TimeUnix), now()) AS " + alias,
      ch.from(database, table),
      ch.where(['$timeFilter'] + predicates),
      'GROUP BY t, ' + std.join(', ', [ch.aliasOf(g) for g in groupBy]),
      'UNION ALL SELECT toUnixTimestamp(toStartOfMinute(now())) * 1000'
      + std.join('', [", '__none__'" for g in groupBy]) + ', 0',
    ]) + '\n',

  // `expr AS alias` -> `alias`, for reuse in GROUP BY.
  aliasOf(sel)::
    local hits = std.findSubstr(' AS ', sel);
    if std.length(hits) == 0 then sel else sel[hits[std.length(hits) - 1] + 4:],

  // Template-variable queries. A short fixed window rather than $timeFilter, so
  // dropdowns load fast regardless of the dashboard's range, and always narrowed
  // by ServiceName/MetricName so they prune on the primary index.
  variableWindow:: 'TimeUnix > now() - INTERVAL 1 HOUR',


  // ---- ratios of two metrics ------------------------------------------------
  //
  // A percentage whose numerator and denominator are SEPARATE metrics —
  // container CPU (usage.total / usage.system) and memory (usage.total /
  // usage.limit).
  //
  // Three things are load-bearing, and all three are invisible if wrong:
  //
  //   1. ONE pass with conditional aggregation, not a join of two subqueries. A
  //      join doubles the scan and silently drops any bucket where only one side
  //      reported, which reads as a gap rather than as missing data.
  //   2. The ratio is formed PER INSTANCE before aggregating across them.
  //      Dividing a summed numerator by a summed denominator is a different
  //      number — it weights every container equally regardless of its limit —
  //      and still looks plausible.
  //   3. nullIf on the denominator. A zero there renders as a spike, which reads
  //      as a real measurement; null renders as the gap it actually is.
  //
  // `instanceExpr` is a parameter because the container metrics identify an
  // instance by Attributes['container_id'], not by the
  // ResourceAttributes['service.instance.id'] the counter builders assume.
  metricsPredicates(metrics, serviceName=null)::
    std.prune([
      if serviceName != null then "ServiceName = '" + serviceName + "'" else null,
      'MetricName IN (' + std.join(', ', ["'" + m + "'" for m in metrics]) + ')',
      ch.recorded,
    ]),

  // Ratio of two GAUGES sampled in the same bucket.
  // `sample` picks WHICH of the bucket's readings the numerator keeps, and at a
  // scrape interval shorter than the bucket that is several readings, not one.
  // It is the single biggest lever on the result: a gauge that moves within a
  // bucket — container memory is the usual case — shifts the line further by
  // this choice than by any other decision in this builder.
  //
  //   'max'   the bucket's PEAK. What a panel titled "memory max" means: the
  //           most memory the container held during that minute. Default,
  //           because a peak is a fact about the interval — an average of peaks
  //           is not a peak of anything, and understates real pressure.
  //   'last'  whichever reading happened to land last. Cheap, and fine for a
  //           slow-moving gauge, but on a noisy one it is close to an arbitrary
  //           draw from the bucket's range — it scatters rather than biasing,
  //           which is harder to spot than a consistent offset.
  //   'avg'   the bucket's mean. What a tool that rolls a gauge up to chart
  //           resolution typically shows; use it only when matching such a
  //           chart matters more than the reading being true.
  //
  // The DENOMINATOR always takes anyLastIf, not `sample`. It is a limit or
  // capacity, which does not move within a bucket — and pairing max-over-readings
  // on both sides would divide a peak by a peak drawn from a different instant.
  // Check that assumption holds for the denominator before using this.
  local gaugeSampleAgg = {
    max: 'maxIf',
    last: 'anyLastIf',
    avg: 'avgIf',
  },

  gaugeRatioQuery(database,
                  numerator,
                  denominator,
                  keyExpr,
                  alias,
                  predicates,
                  instanceExpr,
                  scale=100,
                  agg='max',
                  sample='max')::
    assert std.objectHas(gaugeSampleAgg, sample) :
           "gaugeRatioQuery: sample must be 'max', 'last' or 'avg', got " + sample;
    std.join('\n', [
      'SELECT t, series, ' + agg + '(ratio) AS ' + alias,
      'FROM (',
      '  SELECT $timeSeries AS t,',
      '    ' + keyExpr + ' AS series,',
      '    ' + instanceExpr + ' AS instance,',
      '    ' + std.toString(scale) + ' * ' + gaugeSampleAgg[sample]
      + "(Value, MetricName = '" + numerator + "')",
      "      / nullIf(anyLastIf(Value, MetricName = '" + denominator + "'), 0) AS ratio",
      '  ' + ch.from(database, ch.tables.gauge),
      '  ' + ch.where(['$timeFilter'] + predicates),
      '  GROUP BY t, series, instance',
      ')',
      'GROUP BY t, series',
      'ORDER BY t',
    ]) + '\n',

  // Ratio of two CUMULATIVE counters, differenced per instance first.
  //
  // Both sides must be differenced: the ratio of two lifetime totals is an
  // average over the container's whole life, not the current utilisation, and it
  // is a smooth plausible line that simply never moves. `rn > 1` drops each
  // series' first bucket, where lagInFrame returns 0.
  counterRatioQuery(database,
                    numerator,
                    denominator,
                    keyExpr,
                    alias,
                    predicates,
                    instanceExpr,
                    scale=100,
                    agg='max'):: std.join('\n', [
    'SELECT t, series, ' + agg + '(ratio) AS ' + alias,
    'FROM (',
    '  SELECT t, series, instance,',
    '    ' + std.toString(scale) + ' * (n - prev_n) / nullIf(d - prev_d, 0) AS ratio',
    '  FROM (',
    '    SELECT t, series, instance, n, d,',
    '      lagInFrame(n) OVER (PARTITION BY series, instance ORDER BY t) AS prev_n,',
    '      lagInFrame(d) OVER (PARTITION BY series, instance ORDER BY t) AS prev_d,',
    '      row_number() OVER (PARTITION BY series, instance ORDER BY t) AS rn',
    '    FROM (',
    '      SELECT $timeSeries AS t,',
    '        ' + keyExpr + ' AS series,',
    '        ' + instanceExpr + ' AS instance,',
    "        anyLastIf(Value, MetricName = '" + numerator + "') AS n,",
    "        anyLastIf(Value, MetricName = '" + denominator + "') AS d",
    '      ' + ch.from(database, ch.tables.sum),
    '      ' + ch.where(['$timeFilter'] + predicates),
    '      GROUP BY t, series, instance',
    '    )',
    '  )',
    '  WHERE rn > 1',
    ')',
    'GROUP BY t, series',
    'ORDER BY t',
  ]) + '\n',

  // ---- the APM rollup: otel_traces_apm ---------------------------------------
  //
  // A pre-aggregated span rollup. Everything above this line targets the raw
  // OTel schema; this table differs in three ways, and each one is load-bearing.
  //
  //   1. Every dimension is a FLAT COLUMN — Environment, ServiceName, SpanKind,
  //      SpanName, HttpRoute, HttpStatusCode (the rollup was slimmed in 2026-09:
  //      HttpMethod, Endpoint, DbName, DbSystem, DbOperation and NetPeerName no
  //      longer exist, and one dead identifier fails the whole query). There is
  //      no ResourceAttributes or Attributes map, so ch.dim()'s
  //      resource-vs-datapoint routing has nothing to route and must not be
  //      used here.
  //   2. The measures are aggregate STATES, not values: SpanCount is an
  //      AggregateFunction(count), ErrorCount a countIf state, DurationQuantiles a
  //      quantilesTDigest state. They have to be read through their matching
  //      -Merge combinator. Selecting one raw returns an opaque binary blob
  //      rather than an error, so the aggregates below are named rather than
  //      spelled out per panel.
  //   3. A per-metric attribute check cannot validate these queries: such a
  //      check is keyed by MetricName, and a span query has none. Only a check
  //      that EXECUTES the query reaches this table, so treat an empty panel
  //      here as unexplained until proven otherwise.
  //
  // The time column is `Timestamp` (DateTime), not `TimeUnix` (DateTime64). A
  // panel target must say so, or $timeFilter binds a column that does not exist
  // — see panels.libsonnet's `timeColumn`.
  apmEnvCol:: 'Environment',
  apmTimeCol:: 'Timestamp',
  apmVariableWindow:: 'Timestamp > now() - INTERVAL 1 HOUR',

  // ---- column tenancy: the environment label as a flat column ----------------
  //
  // The environment as a flat column (see identity/profiles/environment_column).
  // The accessor is a plain column, so envIn/envEquals do not apply.
  //
  // There is no prefix/tenant split here, unlike the label grammar above. That
  // split exists to take a suffixed map value apart for a chained pair of
  // dropdowns; this convention offers one dropdown over the whole value, so the
  // column is used as-is and there is nothing to parse. If a chained pair is ever
  // wanted here, reuse envPrefixExpr's shape — but note its no-hyphen case yields
  // '' for a bare `stg`, which would put a blank row in the dropdown.
  //
  // The name of the browse dropdown that isolates one selection under this
  // convention. Where a profile has a tenant axis that variable is `$tenant`,
  // because there it selects a customer within a tier `$env` already picked.
  // Here there is no second dropdown and the value IS the environment, so
  // `$tenant` would put a name on screen that does not describe what it holds.
  //
  // Declared once because three places must agree on it: the predicate below,
  // the dropdown in identity/scopes.libsonnet, and whatever leak-check the
  // consumer runs over rendered dashboards.
  // The browse dropdown that isolates one selection under this convention.
  // Named to match identity/scopes.libsonnet's envVariable, which calls the
  // environment axis `env` for every profile — three places must agree on it:
  // this predicate, that dropdown, and the linter's browse leak-check.
  apmEnvVar:: 'env',

  // Variable-driven membership, for `browse`. Deliberately NOT wrapped in
  // $conditionalTest, for the same reason envIn is not: that helper drops the
  // predicate when the variable is empty, so deselecting every environment would
  // show every one of them. An empty selection must yield no rows.
  apmEnvIn(varName=ch.apmEnvVar):: ch.apmEnvCol + ' IN (${' + varName + ':singlequote})',

  apmEnvEquals(envLabel):: ch.apmEnvCol + " = '" + envLabel + "'",

  // ---- APM aggregate states, read through their combinators ------------------
  apm:: {
    // countMerge over the count state — the span total.
    requests:: 'countMerge(SpanCount)',

    // The rollup's own error state, populated from span status.
    errors:: 'countIfMerge(ErrorCount)',

    // HTTP 5xx, which is a different question from the error state: a span can
    // carry an error status without a 5xx, and vice versa. finalizeAggregation
    // resolves the count state per row so sumIf can filter it by status.
    http5xx:: "sumIf(finalizeAggregation(SpanCount), HttpStatusCode LIKE '5%')",

    // nullIf guards the zero-traffic bucket: without it a window with no spans
    // divides by zero and renders as a spike rather than a gap.
    errorPct(decimals=2)::
      'round(100 * %s / nullIf(%s, 0), %d)' % [ch.apm.errors, ch.apm.requests, decimals],

    http5xxPct(decimals=3)::
      'round(100 * %s / nullIf(%s, 0), %d)' % [ch.apm.http5xx, ch.apm.requests, decimals],

    availabilityPct(decimals=3)::
      'round(100 * (1 - %s / nullIf(%s, 0)), %d)' % [ch.apm.http5xx, ch.apm.requests, decimals],

    // One merge over the tdigest state, indexed per quantile. Merging once and
    // indexing is not a micro-optimisation: a separate merge per quantile reads
    // the state column once per quantile.
    //
    // '%g', not std.toString: go-jsonnet renders 0.9 as `0.90000000000000002`,
    // which ClickHouse accepts but which puts a float-representation artifact in
    // the query text — and a different jsonnet build would emit different bytes
    // for the same source — which is also why a consumer should pin its jsonnet.
    quantiles(qs):: 'quantilesTDigestMerge(' + std.join(', ', ['%g' % q for q in qs]) + ')(DurationQuantiles)',

    // 1-based, matching ClickHouse array indexing.
    quantileAt(qs, index, decimals=1)::
      'round(arrayElement(%s, %d), %d)' % [ch.apm.quantiles(qs), index, decimals],

    quantile(q, decimals=1):: ch.apm.quantileAt([q], 1, decimals),
  },

  // Alias an expression for a SELECT list. Quoted, because APM column titles are
  // display strings with spaces and percent signs ("Err %", "P90 ms") that a bare
  // alias cannot carry.
  apmAs(expr, alias):: expr + ' AS "' + alias + '"',

  // ---- APM query shapes ------------------------------------------------------
  //
  // One builder, three wrappers. Templates compose named aggregates and column
  // names rather than SQL text, so the env predicate and the -Merge combinators
  // cannot be got wrong per panel.
  apmQuery(database, selects, predicates, groupBy=[], having=null, orderBy=null, limit=null)::
    std.join('\n', std.prune([
      'SELECT ' + std.join(',\n  ', selects),
      ch.from(database, ch.tables.apmTraces),
      ch.where(['$timeFilter'] + predicates),
      if std.length(groupBy) > 0 then 'GROUP BY ' + std.join(', ', groupBy) else null,
      if having != null then 'HAVING ' + having else null,
      if orderBy != null then 'ORDER BY ' + orderBy else null,
      if limit != null then 'LIMIT ' + std.toString(limit) else null,
    ])) + '\n',

  // A single-row aggregate, which is what a stat panel reduces.
  apmInstantQuery(database, selects, predicates)::
    ch.apmQuery(database, selects, predicates),

  // $timeSeries must always be paired with GROUP BY t.
  apmSeriesQuery(database, selects, predicates)::
    ch.apmQuery(database, ['$timeSeries AS t'] + selects, predicates, groupBy=['t'], orderBy='t'),

  // ---- one line per series, not one merged line ------------------------------
  //
  // A chart that selects series without aggregating them draws one line PER
  // SERIES. A filter chooses which series are drawn; it does not merge them.
  // Reading a filter as an aggregation collapses the panel to a single line
  // where the original shows many.
  //
  // So a chart that only selects needs this builder, and only one that genuinely
  // aggregates may use apmSeriesQuery above.
  //
  // The key identifies a series the way a legend does —
  // `stg-acme | SERVER | GET | GET | acme-api`. Environment is omitted when the
  // dashboard is pinned to one tenant: it is constant across every series and
  // would only lengthen the legend.
  //
  // ' | ' rather than seriesKey's ' / ', which is a legend convention some tools
  // use and is kept here so a migrated panel reads identically.
  // HttpRoute, not HttpMethod: the rollup slimming (see the contract note
  // above) removed HttpMethod, and one dead identifier fails the whole panel
  // query. HTTP server SpanNames still carry the method ('GET /path'), so
  // the legend loses nothing.
  apmSeriesKeyCols:: ['ServiceName', 'SpanKind', 'HttpRoute', 'SpanName'],

  apmSeriesKey:: 'concat(' + std.join(", ' | ', ", ch.apmSeriesKeyCols) + ')',

  // Emits (t, series, value...) — the same shape counterDeltaQuery produces, and
  // the shape the datasource plugin turns into one Grafana series per `series`
  // value. Keep to ONE value column per target: a string `series` column
  // alongside several numeric ones has no unambiguous reading, so a panel
  // wanting three quantiles uses three targets, as a duration panel
  // already does for its two aggregates.
  apmSeriesByQuery(database, selects, predicates, keyExpr=ch.apmSeriesKey)::
    ch.apmQuery(database,
                ['$timeSeries AS t', keyExpr + ' AS series'] + selects,
                predicates,
                groupBy=['t', 'series'],
                orderBy='t'),

  // One row per distinct value of a dimension column — the tag-breakdown table.
  // LIMIT is mandatory rather than optional: an unbounded breakdown over a
  // high-cardinality column (Endpoint, SpanName) returns every distinct value.
  apmBreakdownQuery(database, column, alias, selects, predicates, orderBy, limit=50, having=null)::
    ch.apmQuery(
      database,
      [ch.apmAs(column, alias)] + selects,
      predicates + [column + " != ''"],
      groupBy=['"' + alias + '"'],
      having=having,
      orderBy=orderBy,
      limit=limit,
    ),
}
