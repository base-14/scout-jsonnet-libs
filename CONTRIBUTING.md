# Contributing

## Setup

```sh
mise install          # pins go-jsonnet, python, uv
uv run --frozen pytest
```

The toolchain pins are not advisory. Jsonnet implementations disagree on
floating-point formatting — `0.6` renders as `0.59999999999999998` under one and
`0.6` under another — so an unpinned toolchain produces diffs that are pure
noise.

## Tests

The library is pure jsonnet, so its tests drive it the way a consumer does:
evaluate an expression and parse the JSON. `tests/conftest.py` provides
`jsonnet_eval()`.

| Suite | Covers |
|---|---|
| `test_sql_builders.py` | Query shapes, directly |
| `test_resolve.py` | Config → instance matrix, and naming |
| `test_identity_conformance.py` | Every profile implements the full contract |
| `test_no_customer_data.py` | Fixtures carry no real deployment identifiers |

Nothing here may depend on a particular deployment's configuration. A test that
reads someone's real config breaks whenever they edit it, and tells you nothing
about the library.

## Fixtures must not name real deployments

Examples, tests and documentation use placeholders. Real hostnames, datasource
identifiers, database names, tenant names and production thresholds must never
appear in this repository — including in commit messages, which are as public as
the code.

| Use | For |
|---|---|
| `app`, `app_stg` | database names |
| `acme`, `big-corp` | tenant names |
| `ds-app`, `ds-app-stg` | datasource identifiers |
| `scout.example.com` | hostnames |

`tests/test_no_customer_data.py` enforces this. Its patterns are **structural**
— they match the shape of a datasource uid or a fully-qualified host, not any
particular name — because a list of real names in a public repository would be
the leak it exists to prevent.

That means bare product or company names cannot be caught here. A deployment
that needs those covered supplies them from outside the repository:

```sh
SCOUT_DENY_EXTRA='foocorp|barinc' uv run --frozen pytest
```

Set that in your own CI. It is deliberately absent from this repo, and the
check is a backstop either way — not a substitute for reading your own diff.

`big-corp` is deliberate: it contains a hyphen, which is the case a naive label
split gets wrong.

## Layering rules

Three rules keep the dependency graph acyclic as the library grows:

1. `core/` never imports `identity/` or `mixins/`.
2. Mixins never import one another, so any mixin can be vendored or deleted alone.
3. A mixin reaches the environment predicate **only** through the identity
   contract, never by writing one itself. A hand-written predicate is correct for
   the deployment it was written against and silently wrong for the next.

Rule 3 is a security boundary, not a style preference. See the Security section
of the README.

## Adding an identity profile

Implement the full contract — `name`, `hasTenant`, `parseLabel`, `composeLabel`,
`scopedPredicate`, `browsePredicate`, `browseSplit`, `browseSplitSelect`,
`envVariableExpr`, `tenantVariableQuery` — and add it to the parametrised list in
`tests/test_identity_conformance.py`.

A profile missing a member does not fail loudly. It renders a query without an
environment predicate, which shows data the viewer should not see.

## Adding a mixin

A mixin exports `name`, `requires(params)`, `dashboards(params)` and
`alerts(params)`.

`requires` declares the metrics the mixin queries, so an integrator can check
them against their own recorded metrics *before* rendering anything — the
difference between "these two panels will be empty" and discovering it
panel-by-panel after a deploy.

Take explicit named arguments rather than an object-merge config. Jsonnet
silently accepts unknown fields in an object merge, so a misspelled key yields
the default with no error; it *does* error on an unknown named argument.

## Commits

Conventional commit prefixes (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`,
`build:`, `chore:`). Explain why the change is correct, not just what changed —
most of what this library guards against fails silently, so the reasoning is the
part worth keeping.
