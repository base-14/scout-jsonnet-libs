// One axis: environment. No tenant.
//
// The common case. Environment scoping is universal — every query must filter
// an environment or be declared `global` — but a tenant axis exists only where
// the operator is itself running a multi-tenant platform.
//
// With no tenant, the label IS the environment: nothing is composed, nothing is
// split, and no tenant dropdown is rendered.
local ch = import '../../core/sql.libsonnet';

{
  name:: 'environmentOnly',
  hasTenant:: false,

  parseLabel(envLabel):: { prefix: envLabel, tenant: null },
  composeLabel(environment, tenant):: environment,

  scopedPredicate(binding):: ch.envEquals(binding.envLabel),

  // The environment dropdown is the only axis, so it carries the filter.
  browsePredicate(envVar, tenantVar):: ch.envIn(envVar),

  browseSplit:: ch.resAttr('environment'),
  browseSplitSelect:: ch.envSelect,

  envVariableExpr:: ch.resAttr('environment'),

  // No tenant dropdown exists — scopes.libsonnet omits it when hasTenant is
  // false. Erroring rather than returning null means a caller that reaches for
  // it anyway fails by name instead of rendering an empty dropdown.
  tenantVariableQuery(dbScope, probeMetric)::
    error 'environmentOnly has no tenant axis; guard on profile.hasTenant',
}
