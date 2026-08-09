// Bare tier in `environment`, tenant in a separate `tenant` resource attribute.
//
// `environment` holds `stg`, never `stg-acme`. Two consequences follow, and
// both are easy to get wrong:
//
//   - A pinned scope must constrain BOTH columns. The tier alone matches every
//     tenant sharing it.
//   - The browse series must split on `tenant`. Splitting on `environment`
//     would draw one line per tier no matter how many tenants are selected,
//     silently defeating the dropdown.
//
// The composed label is still used for uids, folder names and environment-rule
// lookup, which is why this profile implements the grammar too even though no
// query reads it.
local ch = import '../../core/sql.libsonnet';

{
  name:: 'tenantAttribute',
  hasTenant:: true,

  parseLabel(envLabel)::
    local hits = std.findSubstr('-', envLabel);
    if std.length(hits) == 0 then { prefix: envLabel, tenant: null }
    else { prefix: envLabel[0:hits[0]], tenant: envLabel[hits[0] + 1:] },

  composeLabel(environment, tenant):: environment + '-' + tenant,

  scopedPredicate(binding):: ch.envAttrEquals(binding.environment, binding.tenant),

  // Two independent clauses: unlike the label grammar, environment and tenant
  // are not one value chained through a single dropdown.
  browsePredicate(envVar, tenantVar):: ch.envAttrIn(envVar, tenantVar),

  browseSplit:: ch.resTenant,
  browseSplitSelect:: ch.tenantSelect,

  // The column already holds the bare tier — that IS the value. Extracting a
  // prefix would be wrong: the split is on the first hyphen, and a tenant name
  // containing one would silently truncate.
  envVariableExpr:: ch.resAttr('environment'),

  tenantVariableQuery(dbScope, probeMetric):: std.join('\n', [
    'SELECT DISTINCT ' + ch.resTenant + ' AS tenant',
    ch.from(dbScope.database, ch.tables.gauge),
    ch.where([ch.variableWindow] + ch.metricPredicates(probeMetric)
             + [ch.resAttr('environment') + ' IN (${env:singlequote})']),
    'ORDER BY tenant',
  ]) + '\n',
}
