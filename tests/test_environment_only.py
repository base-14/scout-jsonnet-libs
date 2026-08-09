"""A deployment with no tenant axis.

Environment scoping is universal; a tenant axis exists only where the operator
is itself running a multi-tenant platform. environmentOnly is the common case,
so it has to be first-class rather than something the library can only fake.
"""

from __future__ import annotations

from conftest import jsonnet_eval

P = "local p = import 'identity/profiles/init.libsonnet'; "
R = "local r = import 'identity/resolve.libsonnet'; " + P

# No `tenants` key at all — that is the point. Environments are declared
# directly.
CFG = """{
  non_prod_target: 'scout-a',
  targets: {
    'scout-a': { region: 'us-east-1', datasources: { app: 'ds-app', app_stg: 'ds-app-stg' } },
  },
  environments: { rules: [
    { prefix: 'staging', database: 'app_stg', target: 'non-prod' },
    { prefix: 'prod', database: 'app', target: 'non-prod' },
  ] },
  environment_names: ['staging', 'prod'],
}"""


def test_compose_label_is_the_environment_alone():
    assert jsonnet_eval(P + "p.environmentOnly.composeLabel('staging', null)") == "staging"


def test_parse_label_yields_no_tenant():
    got = jsonnet_eval(P + "p.environmentOnly.parseLabel('staging')")
    assert got == {"prefix": "staging", "tenant": None}


def test_scoped_predicate_filters_environment_and_nothing_else():
    got = jsonnet_eval(
        P + "p.environmentOnly.scopedPredicate("
            "{ envLabel: 'staging', environment: 'staging', tenant: null })"
    )
    assert got == "ResourceAttributes['environment'] = 'staging'"
    assert "tenant" not in got


def test_profile_declares_no_tenant_axis():
    assert jsonnet_eval(P + "p.environmentOnly.hasTenant") is False


def test_instances_need_no_tenants():
    got = jsonnet_eval(R + f"r.instances({CFG}, p.environmentOnly)")
    assert [i["environment"] for i in got] == ["staging", "prod"]
    assert all(i["tenant"] is None for i in got)
    assert all(i["envLabel"] == i["environment"] for i in got), (
        "with no tenant axis the label IS the environment"
    )
    assert all(i["datasourceUid"] for i in got)


def test_database_scopes_work_without_tenants():
    got = jsonnet_eval(R + f"r.databaseScopes({CFG}, p.environmentOnly)")
    assert sorted(d["database"] for d in got) == ["app", "app_stg"]


def test_folder_title_degrades_without_a_tenant():
    n = "local n = import 'core/naming.libsonnet'; "
    assert jsonnet_eval(n + "n.scopedFolderTitle(null, 'staging')") == "Staging"
    assert jsonnet_eval(n + "n.scopedFolderTitle('acme', 'staging')") == "Acme / staging"
