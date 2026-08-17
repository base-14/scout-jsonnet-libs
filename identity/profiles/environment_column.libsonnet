// Environment as a FLAT COLUMN, on a pre-aggregated span rollup.
//
// The other profiles all read `ResourceAttributes['environment']`, because the
// raw OTel tables carry their identity in attribute maps. A span rollup has no
// maps at all — every dimension is a materialised column, `Environment` among
// them. Same value grammar as labelSuffix (`stg-acme`), different accessor, so
// none of the map-based helpers apply.
//
// ONE axis, hence hasTenant=false. That is not because the value lacks a tenant
// — it usually contains one — but because there is no second column to filter
// independently. Splitting the label to synthesise a tenant dropdown would mean
// position()/substring() over the column in every panel's WHERE, which defeats
// the index the rollup exists to provide. One dropdown over the whole value is
// both cheaper and closer to what the column means.
local ch = import '../../core/sql.libsonnet';

{
  name:: 'environmentColumn',
  hasTenant:: false,

  // The column holds one opaque value. Consistent with hasTenant=false: nothing
  // is composed and nothing is split.
  parseLabel(envLabel):: { prefix: envLabel, tenant: null },
  composeLabel(environment, tenant):: environment,

  // No pinned form, deliberately — this is a refusal, not an omission.
  //
  // The rollup's Environment column holds BOTH grammars: the suffixed label
  // (`stg-acme`) for services that fold their customer in, and the bare tier
  // (`stg`) for services that carry it elsewhere. A pinned literal therefore
  // isolates a tenant for the former and silently matches nothing for the
  // latter — an empty dashboard with no error, which is the failure mode this
  // whole module exists to prevent.
  //
  // Decide what a scoped asset should mean here before implementing it, and
  // change the lint's scoped branch at the same time.
  scopedPredicate(binding)::
    error 'environmentColumn has no scoped form: the rollup Environment column '
          + 'holds both the suffixed label and the bare tier, so a pinned literal '
          + 'matches nothing for half of them. Use browse, or resolve the grammar first.',

  // The single dropdown carries the filter, as with environmentOnly.
  //
  // Deliberately NOT wrapped in $conditionalTest: that helper drops the
  // predicate when the variable is empty, which here would show every
  // environment instead of none. An empty selection must yield no rows.
  browsePredicate(envVar, tenantVar):: ch.apmEnvIn(envVar),

  browseSplit:: ch.apmEnvCol,
  browseSplitSelect:: ch.apmEnvCol + ' AS environment',

  envVariableExpr:: ch.apmEnvCol,

  // The default env-variable query narrows otel_metrics_gauge by MetricName. A
  // span rollup has no MetricName and is not that table, so this profile
  // supplies the whole query — the same escape hatch tenantVariableQuery gives
  // the tenant axis. scopes.envVariable prefers this when present.
  //
  // `!= ''` drops the rollup's unattributed rows, which would otherwise put a
  // blank entry at the top of the dropdown.
  envVariableQuery(dbScope, probeMetric):: std.join('\n', [
    'SELECT DISTINCT ' + ch.apmEnvCol + ' AS env',
    ch.from(dbScope.database, ch.tables.apmTraces),
    ch.where([ch.apmVariableWindow, ch.apmEnvCol + " != ''"]),
    'ORDER BY env',
  ]) + '\n',

  // No tenant dropdown exists — scopes omits it when hasTenant is false.
  // Erroring rather than returning null means a caller that reaches for it
  // anyway fails by name instead of rendering an empty dropdown.
  tenantVariableQuery(dbScope, probeMetric)::
    error 'environmentColumn has no tenant axis; guard on profile.hasTenant',
}
