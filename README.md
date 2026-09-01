# scout-jsonnet-libs

Jsonnet libraries for generating [base14 Scout](https://base14.io) dashboards and
alerts as code.

Scout is an observability platform that stores OpenTelemetry telemetry in
ClickHouse. Its dashboards, folders and alert rules are declarative
resources, so they can be generated, reviewed in a pull request, and applied by
CI rather than edited by hand in a UI.

This library is the reusable part of doing that: query builders that know the
OpenTelemetry schema, panel scaffolding that matches what Scout stores after it
normalises a dashboard on save, deterministic resource naming, and a small model
for scoping assets to an environment and — optionally — a tenant.

## Status

**Pre-release (`0.x`). The API will change without deprecation cycles.**

Current release: `v0.3.1` — counter-delta alert series, time-series alert queries for multi-dimensional
rules (alertSeriesQuery + per-rule response format), pruneTargets made 25x faster (native containment,
single-pass fold), plus the v0.2.2 zero-row sentinel for instant alert queries,
range threshold evaluators for banded-severity
alert rules, plus the v0.2.0 derived-identity scope, scope-carried CloudWatch
ServiceName scheme, and requires()-driven target pruning
(including the pre-aggregated APM span rollup), the identity contract with
three built-in profiles, and the first three mixins. Pin the tag (or a commit
SHA) rather than `main`:

```sh
jb install github.com/base-14/scout-jsonnet-libs@v0.3.1
```

## Why this exists

Writing a Scout dashboard by hand is easy. Writing four hundred of them, for
several environments, so that every query filters the right environment and none
of them silently return nothing, is not. The failure mode that motivates this
library is that **a wrong observability query does not raise an error** — it
renders an empty panel, or a plausible wrong number, and an alert built on it
simply never fires.

So the library is opinionated in three places where mistakes are silent:

- **Counters.** Selecting a raw cumulative value from a counter table produces a
  smooth rising line that looks like data. The builders compute per-interval
  deltas per series instead, dropping each series' first bucket and clamping
  counter resets.
- **Attribute placement.** OpenTelemetry splits metadata across resource
  attributes and datapoint attributes, and the same key can live in either
  depending on the metric. Reading the wrong one returns an empty result with no
  warning, so dimension access goes through helpers rather than string
  concatenation.
- **Scoping.** Every query must filter its environment. A missing predicate on a
  multi-tenant deployment shows one tenant another's data.

## Requirements

- [go-jsonnet](https://github.com/google/go-jsonnet) 0.20.0 — the implementation
  matters, not just the version: `0.6` renders as `0.59999999999999998` under one
  jsonnet and `0.6` under another, so two contributors on different builds
  produce different bytes.
- [jsonnet-bundler](https://github.com/jsonnet-bundler/jsonnet-bundler) (`jb`)
- Python 3.12 and [uv](https://github.com/astral-sh/uv), to run the tests

## Install

```sh
jb install github.com/base-14/scout-jsonnet-libs@main
```

Then put `vendor/` on the jsonnet search path:

```sh
jsonnet -J vendor your-render.jsonnet
```

## Quickstart

A dashboard is a plain object with a `build` function. It receives a scope —
which supplies the environment predicate and any template variables — and
returns a Scout dashboard.

```jsonnet
local p = import 'github.com/base-14/scout-jsonnet-libs/core/panels.libsonnet';
local ch = import 'github.com/base-14/scout-jsonnet-libs/core/sql.libsonnet';

{
  name: 'go-runtime',
  kind: 'dashboard',
  title: 'Go Runtime',
  modes: ['browse'],

  build(ctx)::
    local s = ctx.scope;

    p.dashboard(
      title=$.title,
      variables=s.variables,
      panels=[
        p.timeseries(1, 'Goroutines', { h: 8, w: 12, x: 0, y: 0 }, [
          p.target(
            s.datasourceUid,
            s.database,
            ch.tables.gauge,
            ch.timeSeriesQuery(
              s.database,
              ch.tables.gauge,
              'go_goroutines',
              'max(Value)',
              'goroutines',
              ch.metricPredicates('go_goroutines') + [s.envPredicate],
            ),
          ),
        ]),
      ],
    ),
}
```

`s.envPredicate` is the part that matters: the scope decides how an environment
is identified, so the same dashboard renders correctly whether the deployment
has a tenant dimension or not.

## Concepts

### Layers

| Layer | Contents |
|---|---|
| `core/` | Query builders, panel scaffolding, the resource envelope, naming. No opinion on how environments are identified. |
| `identity/` | Scope modes and identity profiles. |
| `mixins/` | Ready-made asset bundles — see the index below. |

Dependencies run strictly downward. Mixins never import one another, and a mixin
reaches the environment predicate only through the identity contract — so a
mixin written against one deployment model works under another.

### The modules

Everything importable, and what each piece is for:

| Module | Provides |
|---|---|
| `core/sql.libsonnet` | ClickHouse query builders over the OTel schema: attribute placement, counter deltas/rates, predicates. The layer where silent-empty-result mistakes are prevented. |
| `core/panels.libsonnet` | Dashboard, timeseries, stat and row scaffolding matched to what Scout stores on save, plus presentation overlays (`bars`, `steps`, `legend`). |
| `core/cloudwatch.libsonnet` | CloudWatch metric-stream access: the JSON-encoded `Dimensions` attribute, stream panel targets, dimension dropdowns. Shared by the AWS mixins. |
| `core/manifest.libsonnet` | Scout resource manifests, and the one home of Scout's wire identifiers. |
| `core/naming.libsonnet` | Deterministic uids, titles and folder placement — what makes push idempotent and diffs readable. |
| `core/alerts.libsonnet` | Alert rule construction (authoring shape not yet verified against a live server — see the file header). |
| `core/compat.libsonnet` | Scout version → the schema/plugin/API constants a render must emit. |
| `core/overlay.libsonnet` | The preview overlay: rewrites folders, uids and contact points so local and CI previews cannot touch real assets or page real contact points. |
| `identity/scopes.libsonnet` | The `scoped` / `browse` / `global` scope constructors. |
| `identity/derived.libsonnet` | The derived scope: an identity axis extracted from resource names, for telemetry that carries no identity attributes. |
| `identity/resolve.libsonnet` | Config → instance matrix: which (tenant, environment) lands on which target, database and datasource. |
| `identity/profiles/` | Built-in identity profiles and the contract a custom one implements. |

### Identity profiles

Every deployment has environments. Only some have tenants. A profile is a small
object that answers, for a given scope: which predicate filters this
environment, and which expression distinguishes one series from another.

| Profile | Shape |
|---|---|
| `environmentOnly` | One axis: an `environment` resource attribute. |
| `tenantAttribute` | `environment` holds the bare tier; a separate `tenant` attribute holds the customer. |
| `labelSuffix` | The tenant is folded into the environment label, e.g. `staging-acme`. |

A deployment whose scheme matches none of these can supply its own object
implementing the same contract. `tests/test_identity_conformance.py` is exported
for exactly that purpose — run it against your profile.

### Mixins

A mixin is a ready-made asset bundle: import it, hand its dashboards a scope,
render. Each exports the same contract — `name`, `requires()`, `dashboards()`,
`alerts()` — and works under any identity profile, because scoping only ever
comes from the scope you pass in.

| Mixin | Covers | Telemetry source |
|---|---|---|
| `mixins/aws_elb.libsonnet` | AWS Application ELB: hosts, response codes, requests, connections, latency | CloudWatch metric stream |
| `mixins/aws_rds.libsonnet` | AWS RDS / Aurora: latencies, lags, IOPS, storage, memory, CPU, DB load | CloudWatch metric stream |
| `mixins/rabbitmq.libsonnet` | RabbitMQ: queue depths, consumers, per-node memory/disk, queue/channel/connection churn | OTel `rabbitmq` receiver |

```jsonnet
local elb = import 'github.com/base-14/scout-jsonnet-libs/mixins/aws_elb.libsonnet';

// Check elb.requires().metrics against what your deployment records first —
// the difference between "these panels will be empty" and finding out later.
[t.build({ scope: myScope }) for t in elb.dashboards()]
```

These are ports of dashboards that ran against live deployments, with their
hand-written scoping replaced by the identity contract and their silent bugs
(contradictory predicates, mislabelled units, filters that excluded the rows a
panel was built to show) fixed rather than copied — each mixin's header comment
lists exactly what was corrected and why.

### Scope modes

- `scoped` — one asset per instance, everything pinned, no dropdowns.
- `browse` — one asset with dropdowns over the available environments.
- `global` — no environment dimension at all, for platform-level telemetry such
  as collector health.

`global` is the only mode exempt from the environment-filter requirement, which
is why it must be declared explicitly rather than inferred from a query that
happens to lack a predicate.

## Compatibility

Each Scout release fixes the dashboard `schemaVersion`, the plugin version,
and the resource API versions a render must emit. Getting them wrong does not error — Scout normalises on save,
so a mismatched render produces a permanent diff against the server on every
asset.

Declare one version and let the rest follow. The supported set lives in
`core/compat.libsonnet`; an unsupported version fails the render by name rather
than emitting the wrong constants.

## Security

Read this before writing a custom identity profile.

A profile decides the environment predicate. A profile that omits it produces a
query which is valid, returns rows, and shows data from environments or tenants
the viewer should not see. Nothing in this library can detect that — by the time
the profile has run, the predicate is simply absent.

**Your rendering pipeline must validate the generated SQL**, not the profile:
fail any `scoped` or `browse` query that does not filter its environment. The
safety net has to sit downstream of the extension point. If you adopt custom
profiles without that check, you have removed the only thing standing between a
one-line mistake and a cross-tenant data leak.

To report a vulnerability, please use GitHub's private vulnerability reporting
on this repository rather than opening a public issue.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the
development setup, the test layout, and the rules for fixtures.

```sh
uv run --frozen pytest
```

## License

MIT — see [LICENSE](LICENSE).
