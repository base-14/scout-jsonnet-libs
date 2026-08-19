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

  // ---- identity ------------------------------------------------------------
  //
  // `profile` decides how an environment — and optionally a tenant — is
  // identified. It is passed in rather than chosen here, because one deployment
  // can span more than one convention: one template's metrics may fold the
  // tenant into the environment label while another's carry it as a separate
  // resource attribute.
  //
  // Declared by the caller, never inferred. Inferring it — say, from whether a
  // metric happens to carry `tenant` — would silently pick the wrong convention
  // for some panels of a template that mixes both. Declaring makes it one
  // reviewable line.
  //
  // See identity/profiles/ for the built-ins and the contract a custom profile
  // must satisfy.

  // ---- scoped: pinned to one instance --------------------------------------
  scoped(binding, profile):: {
    mode: 'scoped',
    database: binding.database,
    datasourceUid: binding.datasourceUid,
    envLabel: binding.envLabel,
    tenant: binding.tenant,
    environment: binding.environment,
    // Exposed so a template can reach browseSplit/browseSplitSelect without
    // branching on a convention name.
    profile:: profile,
    // Index-friendly exact match. What "pinned" means is the profile's call:
    // under a separate-tenant-attribute convention the composed label never
    // appears in the data, so both columns have to be constrained.
    envPredicate:: profile.scopedPredicate(binding),
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
  browse(dbScope, probeMetric, profile):: {
    mode: 'browse',
    database: dbScope.database,
    datasourceUid: dbScope.datasourceUid,
    envPrefixes: dbScope.envPrefixes,
    profile:: profile,
    envPredicate:: profile.browsePredicate('env', 'tenant'),
    variables:: [s.envVariable(dbScope, probeMetric, profile)]
                + (
                  if profile.hasTenant
                  then [s.tenantVariable(dbScope, probeMetric, profile)]
                  else []
                ),
    labels:: {},
  },

  // ---- global: tenant-agnostic ---------------------------------------------
  //
  // The ONLY mode exempt from "every query filters its environment", and the
  // exemption is declared by the template rather than inferred from a missing
  // predicate. If it were inferred, a scoped template with a forgotten
  // predicate would read as global, pass lint, and expose every tenant's data.
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

  // Every dropdown from one constructor. `allValue: null` is not an omission: a
  // custom all-value of `*` breaks the IN clause, so "All" must expand to
  // explicit values.
  //
  // `multi`/`includeAll` are parameters because not every dashboard wants them.
  // A dashboard whose panels draw one series per selected value — an APM chart
  // over a high-cardinality dimension, say — multiplies its line count by the
  // selection, and "All" on such a panel renders something nobody asked for.
  queryVariable(name, label, datasourceUid, query, multi=true, includeAll=true):: {
    name: name,
    label: label,
    type: 'query',
    multi: multi,
    includeAll: includeAll,
    allValue: null,
    refresh: 1,
    datasource: { type: manifest.datasourceType, uid: datasourceUid },
    query: query,
    current: {},
    options: [],
    hide: 0,
  },

  // The environment axis, restricted to what this database scope holds.
  //
  // Whether the column needs a prefix extracted is the profile's call: if it
  // already holds the bare tier, extracting would truncate a tenant name that
  // contains a hyphen.
  envVariable(dbScope, probeMetric, profile, multi=true, includeAll=true):: {
    name: 'env',
    label: 'Environment',
    type: 'query',
    multi: multi,
    includeAll: includeAll,
    // No custom allValue: `*` would break the IN clause. "All" must expand to
    // explicit values.
    allValue: null,
    refresh: 1,
    datasource: { type: manifest.datasourceType, uid: dbScope.datasourceUid },
    // The default narrows otel_metrics_gauge by MetricName, which assumes the
    // environment is discoverable from a metric. A profile whose identity lives
    // somewhere else entirely — a span rollup has no MetricName and is not that
    // table — supplies the whole query instead, exactly as tenantVariableQuery
    // lets it own the tenant axis. Optional, so the built-in profiles that are
    // happy with the default declare nothing.
    query: if std.objectHasAll(profile, 'envVariableQuery')
    then profile.envVariableQuery(dbScope, probeMetric)
    else std.join('\n', [
      'SELECT DISTINCT ' + profile.envVariableExpr + ' AS env',
      ch.from(dbScope.database, ch.tables.gauge),
      ch.where([ch.variableWindow] + ch.metricPredicates(probeMetric)),
      'ORDER BY env',
    ]) + '\n',
    current: {},
    options: [],
    hide: 0,
  },

  // Rendered only when the profile has a tenant axis. What the dropdown's value
  // means — a bare tenant name, or a full composed label — is the profile's
  // decision, so the whole query comes from there.
  tenantVariable(dbScope, probeMetric, profile, multi=true, includeAll=true):: {
    name: 'tenant',
    label: 'Tenant',
    type: 'query',
    multi: multi,
    includeAll: includeAll,
    allValue: null,
    refresh: 1,
    datasource: { type: manifest.datasourceType, uid: dbScope.datasourceUid },
    query: profile.tenantVariableQuery(dbScope, probeMetric),
    current: {},
    options: [],
    hide: 0,
  },

  // A dropdown over one of the span rollup's flat dimension columns — $service,
  // $api and the like. Chained: each narrows by the selections above it, so
  // picking a service does not offer another service's endpoints.
  //
  // Not expressible through envVariable/tenantVariable: those narrow
  // otel_metrics_gauge by MetricName, and this table holds spans, has no
  // MetricName, and would list only the values that emit the probe metric.
  //
  // `!= ''` drops the rollup's unattributed rows, which would otherwise put a
  // blank entry at the top of every dropdown.
  apmDimensionVariable(database,
                       datasourceUid,
                       name,
                       label,
                       column,
                       predicates,
                       multi=true,
                       includeAll=true):: s.queryVariable(
    name,
    label,
    datasourceUid,
    std.join('\n', [
      'SELECT DISTINCT ' + column + ' AS ' + name,
      ch.from(database, ch.tables.apmTraces),
      ch.where([ch.apmVariableWindow, column + " != ''"] + predicates),
      'ORDER BY ' + name,
    ]) + '\n',
    multi=multi,
    includeAll=includeAll,
  ),
}
