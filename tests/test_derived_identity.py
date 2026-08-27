"""The derived scope: identity extracted from resource names.

Some telemetry carries no environment or tenant attributes — CloudWatch
stream metrics are the canonical case — and identity lives only in resource
NAMES. derived.scope decorates a global scope with a predicate and dropdown
built from a consumer-supplied extraction expression. The expression itself
never enters this library.
"""

from conftest import jsonnet_eval

PRELUDE = (
    "local scopes = import 'identity/scopes.libsonnet';"
    "local derived = import 'identity/derived.libsonnet';"
    "local base = scopes.global('t1', 'db1', 'ds1') {cloudwatchService:: 'namespace'};"
    "local spec = {envExpr: \"extract(x, 'p')\","
    " probeMetric: 'amazonaws.com/AWS/ApplicationELB/RequestCount'};"
)


def eval_scope(expr):
    # ::-hidden fields don't survive JSON manifestation; project what we assert on.
    return jsonnet_eval(
        PRELUDE + "local s = " + expr + ";"
        "{mode: s.mode, envPredicate: s.envPredicate, variables: s.variables,"
        " database: s.database, datasourceUid: s.datasourceUid}"
    )


def test_predicate_is_membership_over_the_extraction():
    s = eval_scope("derived.scope(base, spec)")
    assert s["envPredicate"] == "extract(x, 'p') IN (${env:singlequote})"


def test_mode_stays_global():
    s = eval_scope("derived.scope(base, spec)")
    assert s["mode"] == "global"
    assert s["database"] == "db1"
    assert s["datasourceUid"] == "ds1"


def test_filter_false_drops_the_predicate_but_keeps_the_dropdown():
    s = eval_scope("derived.scope(base, spec {filter: false})")
    assert s["envPredicate"] is None
    assert len(s["variables"]) == 1


def test_the_dropdown():
    s = eval_scope("derived.scope(base, spec)")
    (v,) = s["variables"]
    assert v["name"] == "env"
    assert v["multi"] is True and v["includeAll"] is True
    assert v["allValue"] is None
    assert v["datasource"]["uid"] == "ds1"
    q = v["query"]
    assert "SELECT DISTINCT extract(x, 'p') AS env" in q
    assert "FROM db1.otel_metrics_summary" in q
    # metric predicates through the scope's ServiceName scheme
    assert "ServiceName = 'AWS/ApplicationELB'" in q
    assert "MetricName = 'amazonaws.com/AWS/ApplicationELB/RequestCount'" in q
    # off-grammar rows extract as '' and stay out of the options
    assert "env != ''" in q


def test_extra_predicates_reach_the_option_query():
    s = eval_scope(
        "derived.scope(base, spec {extraPredicates: [\"x LIKE 'a%'\"]})"
    )
    assert "x LIKE 'a%'" in s["variables"][0]["query"]
