// The derived scope: identity extracted from resource names.
//
// Some telemetry carries no environment or tenant attributes at all —
// CloudWatch stream metrics are the canonical case: their resource attributes
// are exporter identity, and the deployment's environments and tenants exist
// only in resource NAMES inside the Dimensions blob. No identity profile can
// bind to that, and rendering `global` without more gives one undifferentiated
// all-fleet view.
//
// This decorator gives a global scope an identity axis without creating a
// fourth mode: the consumer supplies an SQL expression that extracts a label
// per row, and the scope gains the matching predicate and dropdown. What the
// expression extracts — and whether off-grammar rows collapse to a bucket like
// 'other' or vanish as '' — is entirely the consumer's decision; no
// deployment's naming ever enters this library.
//
// The predicate is plain IN, never $conditionalTest: deselecting everything
// must yield no rows, not every value — the same stance as ch.envIn.
local cw = import '../core/cloudwatch.libsonnet';
local manifest = import '../core/manifest.libsonnet';
local ch = import '../core/sql.libsonnet';

{
  local d = self,

  // spec:
  //   envExpr          SQL expression producing the identity label per row
  //   probeMetric      full stream metric name for the dropdown's option query
  //   extraPredicates  additional WHERE clauses for the option query ([])
  //   filter           false drops the IN predicate so every query is
  //                    executable end to end — the verification render (true)
  scope(base, spec)::
    local full = { extraPredicates: [], filter: true } + spec;
    base {
      envPredicate::
        if full.filter
        then full.envExpr + ' IN (${env:singlequote})'
        else null,
      variables:: [d.envVariable(self, full)],
    },

  // The derived dropdown. Multi-select with an explicit-values "All" — no
  // custom allValue, `*` would break the IN clause — exactly like the identity
  // profiles' envVariable. `env != ''` keeps rows outside the consumer's name
  // grammar out of the options; alias reference in WHERE is ClickHouse-legal.
  envVariable(s, full):: {
    name: 'env',
    label: 'Environment',
    type: 'query',
    multi: true,
    includeAll: true,
    allValue: null,
    refresh: 1,
    datasource: { type: manifest.datasourceType, uid: s.datasourceUid },
    query: std.join('\n', [
      'SELECT DISTINCT ' + full.envExpr + ' AS env',
      ch.from(s.database, ch.tables.summary),
      ch.where(
        [ch.variableWindow]
        + ch.metricPredicates(full.probeMetric, cw.serviceNameFor(s, full.probeMetric))
        + full.extraPredicates
        + ["env != ''"]
      ),
      'ORDER BY env',
    ]) + '\n',
    current: {},
    options: [],
    hide: 0,
  },
}
