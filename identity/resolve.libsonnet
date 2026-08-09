// Resolution: environment label -> data binding + deployment target.
//
// Three lookups, each with exactly one owner:
//   database        config/environments.yaml, region-independent
//   target          q/stg -> non_prod_target;  prod -> the tenant's prod_region
//   datasource uid  that target's `datasources` map
//
// `cfg` is .build/config.json, assembled by scripts/collect_config.py from the
// YAML in config/ and tenants/. Python does the collecting because jsonnet has
// neither globbing (to find tenant files) nor YAML parsing we want to rely on.
{
  local r = self,

  // ---- environment label grammar -------------------------------------------
  //
  // A label is `<prefix>` or `<prefix>-<tenant>`. The tenant part may itself
  // contain hyphens, so the split is on the FIRST hyphen only: `stg-big-corp`
  // parses as (stg, big-corp), not (stg, big).
  //
  // This is the single definition of the grammar. The same split is applied in
  // SQL by sql.libsonnet's envPrefixExpr/envTenantExpr, and in Python by
  // scripts/labels.py, so the three cannot disagree.
  parseLabel(envLabel)::
    local hits = std.findSubstr('-', envLabel);
    if std.length(hits) == 0 then
      { prefix: envLabel, tenant: null }
    else
      { prefix: envLabel[0:hits[0]], tenant: envLabel[hits[0] + 1:] },

  envLabel(environment, tenant):: environment + '-' + tenant,

  // ---- rules ---------------------------------------------------------------

  // First rule whose prefix matches, or null. Matches an exact prefix (`prod`)
  // or the prefix followed by a hyphen (`prod-acme`) — never a bare
  // string-prefix, so `production` does not match the `prod` rule.
  envRule(cfg, envLabel)::
    local p = r.parseLabel(envLabel).prefix;
    local hits = [rule for rule in cfg.environments.rules if rule.prefix == p];
    if std.length(hits) == 0 then null else hits[0],

  // Which target does this (envLabel, tenant) land on?
  targetName(cfg, envLabel, tenant)::
    local rule = r.envRule(cfg, envLabel);
    if rule == null then
      error 'no environment rule matches label %s (prefix %s). Add one to config/environments.yaml.'
            % [envLabel, r.parseLabel(envLabel).prefix]
    else if rule.target == 'non-prod' then
      cfg.non_prod_target
    else if rule.target == 'per-tenant-region' then
      local region = std.get(tenant, 'prod_region', null);
      if region == null then
        error 'tenant %s declares environment %s but has no prod_region' % [tenant.tenant, envLabel]
      else
        local matches = [
          name
          for name in std.objectFields(cfg.targets)
          if cfg.targets[name].region == region
        ];
        if std.length(matches) == 0 then
          error 'tenant %s has prod_region %s, but no target in config/targets.yaml serves that region'
                % [tenant.tenant, region]
        else matches[0]
    else
      error 'unknown target directive %s in config/environments.yaml' % rule.target,

  // The full binding for one (tenant, environment) instance.
  binding(cfg, tenant, environment)::
    local envLabel = r.envLabel(environment, tenant.tenant);
    local rule = r.envRule(cfg, envLabel);
    local targetName = r.targetName(cfg, envLabel, tenant);
    local target = cfg.targets[targetName];
    local ds = std.get(target.datasources, rule.database, null);
    if ds == null then
      error 'target %s has no datasource for database %s, needed by %s'
            % [targetName, rule.database, envLabel]
    else {
      tenant: tenant.tenant,
      environment: environment,
      envLabel: envLabel,
      database: rule.database,
      targetName: targetName,
      target: target { name: targetName },
      datasourceUid: ds,
    },

  // ---- the instance matrix -------------------------------------------------

  // Every (tenant, environment) pair, resolved. This is what `scoped` renders over.
  instances(cfg):: std.flattenArrays([
    [r.binding(cfg, t, env) for env in t.environments]
    for t in cfg.tenants
  ]),

  // Distinct (target, database) pairs — what `browse` and data-querying `global`
  // assets render over. Derived from the instance matrix rather than declared, so
  // a target only gets a browse asset for a database some tenant actually uses.
  databaseScopes(cfg)::
    local insts = r.instances(cfg);
    local keys = std.set([i.targetName + '/' + i.database for i in insts]);
    [
      local parts = std.splitLimit(k, '/', 1);
      local sample = [i for i in insts if i.targetName == parts[0] && i.database == parts[1]][0];
      {
        targetName: parts[0],
        target: sample.target,
        database: parts[1],
        datasourceUid: sample.datasourceUid,
        // Which environment prefixes this database scope actually contains —
        // the option list for the browse `$env` variable.
        envPrefixes: std.set([
          r.parseLabel(i.envLabel).prefix
          for i in insts
          if i.targetName == parts[0] && i.database == parts[1]
        ]),
      }
      for k in keys
    ],

  // Every target — what query-less `global` assets render over.
  targetNames(cfg):: std.objectFields(cfg.targets),

  // ---- thresholds ----------------------------------------------------------

  // Precedence: tenant's per-environment override > config/defaults.yaml.
  threshold(cfg, tenant, environment, key)::
    local envOverrides = std.get(std.get(tenant, 'thresholds', {}), environment, {});
    std.get(envOverrides, key, std.get(cfg.defaults.thresholds, key, null)),

  // Does this instance override ANY threshold? If so it renders as a scoped
  // alert rule and is excluded from the shared multi-dimensional rule.
  overridesThresholds(tenant, environment)::
    std.length(std.objectFields(std.get(std.get(tenant, 'thresholds', {}), environment, {}))) > 0,

  // ---- contact points ------------------------------------------------------

  contactPoint(cfg, tenant, environment)::
    local cps = std.get(tenant, 'contact_points', {});
    std.get(cps, environment, std.get(cps, 'default', null)),

  tenantByName(cfg, name)::
    local hits = [t for t in cfg.tenants if t.tenant == name];
    if std.length(hits) == 0 then error 'no such tenant: ' + name else hits[0],
}
