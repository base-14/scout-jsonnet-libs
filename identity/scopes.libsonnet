// The three scope modes. A scope is what turns one template into an artifact:
// it supplies the environment predicate and any dashboard variables.
//
// The template itself never changes between modes — panels, queries, and
// thresholds are shared. A tenant-specific dashboard IS the browse dashboard
// with a pinned scope. See the README's Scope modes section.
local manifest = import '../core/manifest.libsonnet';
local ch = import '../core/sql.libsonnet';

{
  local s = self,

  // ---- tenancy: which convention a template's metrics follow ---------------
  //
  // Two conventions can coexist in one deployment, split by tech stack:
  //
  //   'label'      the tenant is folded into a suffixed environment label
  //                (`stg-acme`), with no `tenant` resource attribute at all.
  //   'attribute'  `environment` holds the bare tier (`stg`) and the tenant
  //                is carried separately as ResourceAttributes['tenant'].
  //
  // Declared per template via `tenancy: 'attribute'|'label'`, the same way
  // `mode: global` is declared rather than inferred — see `global` below. If it
  // were inferred (say, from whether a metric happens to carry `tenant`), a
  // template mixing both conventions across its panels would silently pick the
  // wrong one for some of them. Declaring it instead makes the choice a single,
  // reviewable line, and a template that is never migrated keeps working under
  // 'label' by default.
  local ATTRIBUTE = 'attribute',

  // ---- scoped: pinned to one (tenant, environment) instance ----------------
  scoped(binding, tenancy='label'):: {
    mode: 'scoped',
    database: binding.database,
    datasourceUid: binding.datasourceUid,
    envLabel: binding.envLabel,
    tenant: binding.tenant,
    environment: binding.environment,
    tenancy:: tenancy,
    // Index-friendly exact match. Under 'attribute' tenancy the label itself
    // (`stg-acme`) never appears in the data — the bare tier and the tenant are
    // two separate columns, so both must be pinned.
    envPredicate::
      if tenancy == ATTRIBUTE
      then ch.envAttrEquals(binding.environment, binding.tenant)
      else ch.envEquals(binding.envLabel),
    // No variables: everything is baked in, which is the point.
    variables:: [],
    // Labels stamped on alert rules for notification routing.
    labels:: { tenant: binding.tenant, environment: binding.envLabel },
  },

  // ---- browse: dropdowns over one (target, database) scope ------------------
  //
  // Cannot span databases: a deployment may put production and non-production
  // telemetry in different databases, and a panel target's database is fixed.
  // Hence one browse asset per database scope, not one globally.
  browse(dbScope, probeMetric, tenancy='label'):: {
    mode: 'browse',
    database: dbScope.database,
    datasourceUid: dbScope.datasourceUid,
    envPrefixes: dbScope.envPrefixes,
    tenancy:: tenancy,
    // Under 'label' tenancy `$tenant` carries the FULL label as its value while
    // displaying the bare tenant name, so this stays a simple map equality the
    // bloom filter can use. The alternative — position()/substring() predicates
    // in every panel — is correct but forces a full column read per panel.
    //
    // Under 'attribute' tenancy environment and tenant are independent columns,
    // so both dropdowns filter their own.
    envPredicate::
      if tenancy == ATTRIBUTE
      then ch.envAttrIn('env', 'tenant')
      else ch.envIn('tenant'),
    variables:: [
      s.envVariable(dbScope, probeMetric, tenancy),
      s.tenantVariable(dbScope, probeMetric, tenancy),
    ],
    labels:: {},
  },

  // ---- global: tenant-agnostic ---------------------------------------------
  //
  // The ONLY mode exempt from "every query filters its environment label", and
  // the exemption is declared by the template rather than inferred from a missing
  // predicate. If it were inferred, a scoped template with a forgotten predicate
  // would read as global, pass lint, and expose every tenant's data.
  global(target, database=null, datasourceUid=null):: {
    mode: 'global',
    database: database,
    datasourceUid: datasourceUid,
    targetName: target,
    envPredicate:: null,
    variables:: [],
    // No tenant label: a global alert routes to the platform contact point, and
    // a tenant label would send an infrastructure page to a customer's channel.
    labels:: {},
  },

  // ---- browse variables ----------------------------------------------------

  // The environment prefix, restricted to what this database scope holds: the
  // non-production prefixes for the non-production database, and so on.
  //
  // Under 'label' tenancy the value in ResourceAttributes['environment'] is the
  // full suffixed label, so the prefix has to be extracted. Under 'attribute'
  // tenancy the column already holds the bare tier — that IS the value — so no
  // extraction is needed or correct: envPrefixExpr splits on the first hyphen,
  // and a bare `stg` has none, but a tenant name containing one (`big-corp`)
  // would silently truncate.
  envVariable(dbScope, probeMetric, tenancy='label'):: {
    name: 'env',
    label: 'Environment',
    type: 'query',
    multi: true,
    includeAll: true,
    // No custom allValue: `*` would break the IN clause. "All" must expand to
    // explicit values.
    allValue: null,
    refresh: 1,
    datasource: { type: manifest.datasourceType, uid: dbScope.datasourceUid },
    query: std.join('\n', [
      'SELECT DISTINCT ' + (if tenancy == ATTRIBUTE then ch.resAttr('environment') else ch.envPrefixExpr) + ' AS env',
      ch.from(dbScope.database, ch.tables.gauge),
      ch.where([ch.variableWindow] + ch.metricPredicates(probeMetric)),
      'ORDER BY env',
    ]) + '\n',
    current: {},
    options: [],
    hide: 0,
  },

  // Under 'label' tenancy this is chained off $env: displays `acme`, returns
  // `stg-acme`, and the predicate below is a single ResourceAttributes['environment']
  // equality using that full value.
  //
  // Under 'attribute' tenancy `tenant` is its own resource attribute, entirely
  // independent of the environment column, so this reads it directly instead of
  // deriving anything from the environment label.
  tenantVariable(dbScope, probeMetric, tenancy='label'):: {
    name: 'tenant',
    label: 'Tenant',
    type: 'query',
    multi: true,
    includeAll: true,
    allValue: null,
    refresh: 1,
    datasource: { type: manifest.datasourceType, uid: dbScope.datasourceUid },
    query:
      if tenancy == ATTRIBUTE then
        std.join('\n', [
          'SELECT DISTINCT ' + ch.resTenant + ' AS tenant',
          ch.from(dbScope.database, ch.tables.gauge),
          ch.where([ch.variableWindow] + ch.metricPredicates(probeMetric)
                   + [ch.resAttr('environment') + ' IN (${env:singlequote})']),
          'ORDER BY tenant',
        ]) + '\n'
      else
        std.join('\n', [
          'SELECT DISTINCT',
          '  ' + ch.envTenantExpr + ' AS __text,',
          "  ResourceAttributes['environment'] AS __value",
          ch.from(dbScope.database, ch.tables.gauge),
          ch.where([ch.variableWindow] + ch.metricPredicates(probeMetric)
                   + [ch.envPrefixExpr + ' IN (${env:singlequote})']),
          'ORDER BY __text',
        ]) + '\n',
    current: {},
    options: [],
    hide: 0,
  },
}
