// Tenant folded into the environment label: `stg-acme`.
//
// The deployment carries no `tenant` resource attribute at all, so the label is
// the only place the tenant appears. The `$tenant` dropdown holds the FULL
// label as its value while displaying the bare tenant name, which keeps the
// predicate a simple map equality the bloom filter can use. The alternative —
// position()/substring() in every panel's WHERE — is correct but forces a full
// column read per panel.
local ch = import '../../core/sql.libsonnet';

{
  name:: 'labelSuffix',
  hasTenant:: true,

  // Split on the FIRST hyphen, so a tenant name containing hyphens survives:
  // `stg-big-corp` is (stg, big-corp), not (stg, big).
  parseLabel(envLabel)::
    local hits = std.findSubstr('-', envLabel);
    if std.length(hits) == 0 then { prefix: envLabel, tenant: null }
    else { prefix: envLabel[0:hits[0]], tenant: envLabel[hits[0] + 1:] },

  composeLabel(environment, tenant):: environment + '-' + tenant,

  scopedPredicate(binding):: ch.envEquals(binding.envLabel),

  // One clause: the tenant variable already carries the full label, so the
  // environment variable would be redundant here.
  browsePredicate(envVar, tenantVar):: ch.envIn(tenantVar),

  browseSplit:: ch.resAttr('environment'),
  browseSplitSelect:: ch.envSelect,

  // The column holds the full suffixed label, so the tier must be extracted.
  envVariableExpr:: ch.envPrefixExpr,

  // Displays the bare tenant, returns the full label — see the note above.
  tenantVariableQuery(dbScope, probeMetric):: std.join('\n', [
    'SELECT DISTINCT',
    '  ' + ch.envTenantExpr + ' AS __text,',
    "  ResourceAttributes['environment'] AS __value",
    ch.from(dbScope.database, ch.tables.gauge),
    ch.where([ch.variableWindow] + ch.metricPredicates(probeMetric)
             + [ch.envPrefixExpr + ' IN (${env:singlequote})']),
    'ORDER BY __text',
  ]) + '\n',
}
