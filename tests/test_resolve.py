"""Resolution and naming: the pure functions the whole matrix rests on.

The config is synthetic and defined here. A library test must not read a real
deployment's configuration: it would break whenever that deployment changed a
threshold, and it would tell you nothing about the library.
"""

from __future__ import annotations

import pytest

from conftest import jsonnet_eval

# A two-tenant deployment covering both target directives:
#   stg  -> non-prod, one shared target
#   prod -> per-tenant-region
#
# `acme` overrides a threshold; `big-corp` does not, so it exercises the
# fall-through. `big-corp` also carries the hyphen that splitByChar gets wrong.
CFG = """{
  non_prod_target: 'scout-a',
  targets: {
    'scout-a': { region: 'us-east-1', datasources: { app: 'ds-app', app_stg: 'ds-app-stg' } },
    'scout-b': { region: 'eu-west-1', datasources: { app: 'ds-app-eu' } },
  },
  environments: { rules: [
    { prefix: 'stg', database: 'app_stg', target: 'non-prod' },
    { prefix: 'prod', database: 'app', target: 'per-tenant-region' },
  ] },
  defaults: { thresholds: { ingest_lag_seconds: 600 } },
  tenants: [
    { tenant: 'acme', prod_region: 'eu-west-1', environments: ['stg', 'prod'],
      thresholds: { stg: { ingest_lag_seconds: 900 } } },
    { tenant: 'big-corp', prod_region: 'us-east-1', environments: ['stg', 'prod'] },
  ],
}"""

# These fixtures use the label-suffix convention, so that is the profile under
# test here. The tenant-free path has its own suite.
R = ("local r = import 'identity/resolve.libsonnet';"
     " local prof = (import 'identity/profiles/init.libsonnet').labelSuffix;"
     " local c = %s; " % CFG)
N = "local n = import 'core/naming.libsonnet'; "


# ---- the label grammar -----------------------------------------------------


@pytest.mark.parametrize(
    "label,prefix,tenant",
    [
        ("prod-acme", "prod", "acme"),
        ("stg-acme", "stg", "acme"),
        ("q-acme", "q", "acme"),
        # The case splitByChar would get wrong.
        ("stg-big-corp", "stg", "big-corp"),
        ("prod-a-b-c", "prod", "a-b-c"),
        # A bare prefix with no tenant.
        ("prod", "prod", None),
    ],
)
def test_label_splits_on_the_first_hyphen(label, prefix, tenant):
    """A hyphenated tenant name mis-attributed on one side only is the kind of
    bug that shows up as one tenant's dashboard quietly querying another's."""
    got = jsonnet_eval(
        R + "r.parseLabel(prof, '%s')" % label
    )
    assert got["prefix"] == prefix
    assert got["tenant"] == tenant


# ---- resolution ------------------------------------------------------------


def test_non_prod_lands_on_the_non_prod_target():
    """Non-production exists on one target whatever the tenant's prod_region."""
    for tenant in ("acme", "big-corp"):
        got = jsonnet_eval(
            R + "r.targetName(c, prof, 'stg-%s', r.tenantByName(c, '%s'))" % (tenant, tenant)
        )
        assert got == "scout-a", f"stg-{tenant} resolved to {got}, not the non-prod target"


def test_prod_follows_the_tenants_region():
    for tenant, region in (("acme", "eu-west-1"), ("big-corp", "us-east-1")):
        got = jsonnet_eval(
            R + "r.targetName(c, prof, 'prod-%s', r.tenantByName(c, '%s'))" % (tenant, tenant)
        )
        assert jsonnet_eval(R + "c.targets['%s'].region" % got) == region


def test_every_instance_resolves_a_datasource():
    """A missing datasource renders a panel with an empty uid, which fails silently."""
    instances = jsonnet_eval(R + "r.instances(c, prof)")
    assert len(instances) == 4
    for i in instances:
        assert i["datasourceUid"], f"{i['envLabel']} has no datasource"


def test_threshold_precedence():
    """Tenant override beats the default; absence falls through."""
    override = jsonnet_eval(
        R + "r.threshold(c, r.tenantByName(c, 'acme'), 'stg', 'ingest_lag_seconds')"
    )
    assert override == 900, "acme's stg override should win"

    default = jsonnet_eval(
        R + "r.threshold(c, r.tenantByName(c, 'big-corp'), 'stg', 'ingest_lag_seconds')"
    )
    assert default == 600


def test_override_detection_drives_scoped_alerts():
    """Whether an instance gets its own rule is derived, never declared twice."""
    assert jsonnet_eval(
        R + "r.overridesThresholds(r.tenantByName(c, 'acme'), 'stg')"
    ) is True
    assert jsonnet_eval(
        R + "r.overridesThresholds(r.tenantByName(c, 'big-corp'), 'stg')"
    ) is False


# ---- naming ----------------------------------------------------------------


def test_uids_stay_within_the_limit_and_stay_unique():
    """Truncation must not create a collision — that would overwrite an asset."""
    long_a = "prod-averyveryverylongtenantname-service-overview-extra"
    long_b = "prod-averyveryverylongtenantname-service-overview-other"
    a = jsonnet_eval(N + "n.clamp('%s')" % long_a)
    b = jsonnet_eval(N + "n.clamp('%s')" % long_b)
    assert len(a) <= 40 and len(b) <= 40
    assert a != b, "two long uids collapsed to the same value after truncation"


def test_short_uids_are_left_alone():
    assert jsonnet_eval(N + "n.clamp('prod-acme-x')") == "prod-acme-x"
