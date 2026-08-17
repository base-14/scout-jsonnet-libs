"""Every identity profile must implement the full contract.

A profile decides which environment predicate a query carries. A profile
missing a member does not fail loudly — it renders a query without the
predicate, which shows data the viewer should not see.

This suite is exported so an integrator can run it against a custom profile,
which is the only reason the extension point can be open at all.
"""

from __future__ import annotations

import pytest

from conftest import jsonnet_eval

CONTRACT = [
    "name",
    "hasTenant",
    "parseLabel",
    "composeLabel",
    "scopedPredicate",
    "browsePredicate",
    "browseSplit",
    "browseSplitSelect",
    "envVariableExpr",
    "tenantVariableQuery",
]

PROFILES = ["environmentOnly", "environmentColumn", "labelSuffix", "tenantAttribute"]

# Profiles with a pinned form. environmentColumn has none by design: its column
# holds both the suffixed label and the bare tier, so a pinned literal matches
# nothing for half of them — see the profile's scopedPredicate.
SCOPEABLE = ["environmentOnly", "labelSuffix", "tenantAttribute"]

P = "local p = import 'identity/profiles/init.libsonnet'; "

BINDING = (
    "{ envLabel: 'stg-acme', environment: 'stg', tenant: 'acme',"
    " database: 'app_stg', datasourceUid: 'ds-app-stg' }"
)

DB_SCOPE = "{ database: 'app_stg', datasourceUid: 'ds-app-stg', envPrefixes: ['stg'] }"


@pytest.mark.parametrize("profile", PROFILES)
def test_profile_implements_contract(profile):
    fields = jsonnet_eval(P + f"std.objectFieldsAll(p.{profile})")
    missing = [m for m in CONTRACT if m not in fields]
    assert not missing, f"{profile} is missing {missing}"


TENANTED = ["labelSuffix", "tenantAttribute"]


@pytest.mark.parametrize("profile", TENANTED)
def test_parse_and_compose_round_trip(profile):
    """composeLabel then parseLabel must recover the parts."""
    got = jsonnet_eval(
        P + f"local prof = p.{profile};"
        " prof.parseLabel(prof.composeLabel('stg', 'big-corp'))"
    )
    assert got["prefix"] == "stg"
    assert got["tenant"] == "big-corp", "the split must be on the FIRST hyphen"


@pytest.mark.parametrize("profile", SCOPEABLE)
def test_scoped_predicate_filters_the_environment(profile):
    """Whatever the convention, a pinned scope must constrain the environment."""
    got = jsonnet_eval(P + f"p.{profile}.scopedPredicate({BINDING})")
    assert "ResourceAttributes['environment']" in got


def test_label_suffix_pins_the_full_label():
    got = jsonnet_eval(P + f"p.labelSuffix.scopedPredicate({BINDING})")
    assert got == "ResourceAttributes['environment'] = 'stg-acme'"


def test_tenant_attribute_pins_both_columns():
    """The bare tier alone would match every tenant sharing that tier."""
    got = jsonnet_eval(P + f"p.tenantAttribute.scopedPredicate({BINDING})")
    assert "ResourceAttributes['environment'] = 'stg'" in got
    assert "ResourceAttributes['tenant'] = 'acme'" in got


def test_browse_predicates_bind_their_own_variables():
    label = jsonnet_eval(P + "p.labelSuffix.browsePredicate('env', 'tenant')")
    assert "${tenant:singlequote}" in label

    attr = jsonnet_eval(P + "p.tenantAttribute.browsePredicate('env', 'tenant')")
    assert "${env:singlequote}" in attr
    assert "${tenant:singlequote}" in attr


def test_browse_split_distinguishes_selected_tenants():
    """Splitting on the bare tier would draw one line per tier, not per tenant."""
    assert jsonnet_eval(P + "p.tenantAttribute.browseSplit") == "ResourceAttributes['tenant']"
    assert jsonnet_eval(P + "p.labelSuffix.browseSplit") == "ResourceAttributes['environment']"


@pytest.mark.parametrize("profile", TENANTED)
def test_tenant_variable_query_is_bounded_and_indexed(profile):
    q = jsonnet_eval(P + f"p.{profile}.tenantVariableQuery({DB_SCOPE}, 'up')")
    assert "INTERVAL" in q, "a dropdown query must use a short fixed window"
    assert "MetricName = 'up'" in q, "must narrow on the primary index"


def test_environment_column_refuses_a_scoped_form():
    """A refusal, not an omission — it must fail loudly rather than match nothing."""
    with pytest.raises(Exception, match="no scoped form"):
        jsonnet_eval(P + f"p.environmentColumn.scopedPredicate({BINDING})")


def test_environment_column_reads_the_flat_column():
    """The rollup has no attribute maps; a map lookup there returns nothing."""
    pred = jsonnet_eval(P + "p.environmentColumn.browsePredicate('env', 'tenant')")
    assert pred == "Environment IN (${env:singlequote})"
    assert "ResourceAttributes" not in pred


def test_environment_column_env_query_targets_the_rollup():
    """It cannot use the default: a span rollup has no MetricName column."""
    q = jsonnet_eval(P + f"p.environmentColumn.envVariableQuery({DB_SCOPE}, 'up')")
    assert "otel_traces_apm" in q
    assert "MetricName" not in q
    assert "INTERVAL" in q, "a dropdown query must use a short fixed window"


# ---- scopes must delegate, not branch --------------------------------------

S = "local s = import 'identity/scopes.libsonnet'; " + P


@pytest.mark.parametrize(
    "profile,expected",
    [
        ("labelSuffix", "ResourceAttributes['environment'] = 'stg-acme'"),
        ("tenantAttribute", "ResourceAttributes['tenant'] = 'acme'"),
    ],
)
def test_scoped_delegates_to_the_profile(profile, expected):
    got = jsonnet_eval(S + f"s.scoped({BINDING}, p.{profile}).envPredicate")
    assert expected in got


def test_browse_exposes_the_profile_to_templates():
    """A template must be able to reach browseSplit without branching on a name."""
    got = jsonnet_eval(
        S + f"s.browse({DB_SCOPE}, 'up', p.tenantAttribute).profile.browseSplit"
    )
    assert got == "ResourceAttributes['tenant']"


def test_browse_omits_the_tenant_dropdown_without_a_tenant_axis():
    names = jsonnet_eval(
        S + "local prof = p.tenantAttribute { hasTenant:: false,"
            " tenantVariableQuery(d, m):: error 'must not be called' };"
        f" [v.name for v in s.browse({DB_SCOPE}, 'up', prof).variables]"
    )
    assert names == ["env"]
