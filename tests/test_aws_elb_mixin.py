"""The aws-elb mixin: CloudWatch ELB telemetry as a library dashboard.

The reference for this mixin is a hand-built Scout dashboard over CloudWatch
metric-stream data. Its queries carry the two mistakes this library exists to
prevent — hand-written environment predicates, and copy-paste predicates that
contradict the metric they sit next to and so return nothing, silently. These
tests pin the corrected behaviour: scoping comes only from the identity
contract, and every target queries exactly the metric its panel claims.
"""

from __future__ import annotations

from conftest import jsonnet_eval

E = (
    "local elb = import 'mixins/aws_elb.libsonnet'; "
    "local sc = import 'identity/scopes.libsonnet'; "
    "local p = import 'identity/profiles/init.libsonnet'; "
)

# A browse scope over one placeholder database, and a scoped binding pinned to
# staging. Placeholder names per CONTRIBUTING — never real deployments.
BROWSE = (
    "sc.browse({ database: 'app', datasourceUid: 'ds-app', "
    "envPrefixes: ['staging', 'prod'] }, 'go_goroutines', p.environmentOnly)"
)
SCOPED = (
    "sc.scoped({ database: 'app', datasourceUid: 'ds-app', envLabel: 'staging', "
    "tenant: null, environment: 'staging' }, p.environmentOnly)"
)

BROWSE_DASH = E + f"elb.dashboards()[0].build({{ scope: {BROWSE} }})"
SCOPED_DASH = E + f"elb.dashboards()[0].build({{ scope: {SCOPED} }})"

ELB = "amazonaws.com/AWS/ApplicationELB/"

TITLES = [
    "Host Counts by Status",
    "DNS by Status",
    "PeakLCUs",
    "RuleEvaluations",
    "ELB Response Counts by Code",
    "Target Response Counts by Code",
    "Request Count",
    "Request Count per Target",
    "Connection Count",
    "Processed Bytes",
    "TargetResponseTime",
    "HTTP_Fixed_Response_Count",
    "ELB 5xx Responses by Code",
]


def _targets(dash):
    return [t for panel in dash["panels"] for t in panel["targets"]]


def _panel(dash, title):
    return next(p for p in dash["panels"] if p["title"] == title)


def _metrics_of(panel):
    return [
        line.split("'")[1]
        for t in panel["targets"]
        for line in t["query"].split("\n")
        if line.strip().startswith("AND MetricName")
    ]


# ---- the mixin contract ----------------------------------------------------


def test_mixin_exports_the_contract():
    assert jsonnet_eval(E + "elb.name") == "aws-elb"
    assert jsonnet_eval(E + "elb.alerts()") == []


def test_requires_covers_every_queried_metric():
    """`requires` exists so an integrator can diff it against their recorded
    metrics before rendering. A queried metric missing from it defeats that."""
    required = set(jsonnet_eval(E + "elb.requires().metrics"))
    dash = jsonnet_eval(BROWSE_DASH)
    queried = {m for panel in dash["panels"] for m in _metrics_of(panel)}
    assert queried, "no MetricName predicates found at all"
    assert queried == required


# ---- scoping: the security property ----------------------------------------


def test_every_browse_query_filters_environment_via_the_profile():
    dash = jsonnet_eval(BROWSE_DASH)
    for t in _targets(dash):
        assert "ResourceAttributes['environment'] IN (${env:singlequote})" in t["query"]


def test_every_scoped_query_pins_the_environment():
    dash = jsonnet_eval(SCOPED_DASH)
    for t in _targets(dash):
        assert "ResourceAttributes['environment'] = 'staging'" in t["query"]


def test_no_conditional_test_around_the_lb_filter():
    """$conditionalTest drops the predicate when the selection is empty, which
    would widen the result instead of emptying it — same stance as envIn."""
    dash = jsonnet_eval(BROWSE_DASH)
    for t in _targets(dash):
        assert "$conditionalTest" not in t["query"]
        assert (
            "simpleJSONExtractString(Attributes['Dimensions'], 'LoadBalancer') "
            "IN (${loadBalancer:singlequote})" in t["query"]
        )


# ---- variables --------------------------------------------------------------


def test_browse_variables_are_scope_env_plus_loadbalancer():
    dash = jsonnet_eval(BROWSE_DASH)
    names = [v["name"] for v in dash["templating"]["list"]]
    assert names == ["env", "loadBalancer"]


def test_scoped_still_offers_the_loadbalancer_dropdown():
    """Scoped pins the identity axes; the load balancer is a data axis within
    the environment, so the dropdown survives pinning."""
    dash = jsonnet_eval(SCOPED_DASH)
    names = [v["name"] for v in dash["templating"]["list"]]
    assert names == ["loadBalancer"]


def test_loadbalancer_variable_is_env_filtered_and_multi():
    for expr, env_pred in [
        (BROWSE_DASH, "IN (${env:singlequote})"),
        (SCOPED_DASH, "= 'staging'"),
    ]:
        dash = jsonnet_eval(expr)
        lb = next(v for v in dash["templating"]["list"] if v["name"] == "loadBalancer")
        assert lb["multi"] is True
        assert lb["includeAll"] is True
        assert lb["allValue"] is None, "a custom allValue would break the IN clause"
        assert "ResourceAttributes['environment'] " + env_pred in lb["query"]
        assert f"MetricName = '{ELB}RequestCount'" in lb["query"]
        assert "app.otel_metrics_summary" in lb["query"]


# ---- query shape ------------------------------------------------------------


def test_queries_read_the_summary_table_the_stream_writes_to():
    dash = jsonnet_eval(BROWSE_DASH)
    for t in _targets(dash):
        assert t["table"] == "otel_metrics_summary"
        assert "max(Sum)" in t["query"]
        assert "ServiceName = 'aws-cloudwatch-stream'" in t["query"]


def test_no_datapoint_metricname_predicates():
    """The column MetricName already pins the metric; the reference's extra
    Attributes['MetricName'] copies contradicted it on four targets and made
    those series permanently empty."""
    dash = jsonnet_eval(BROWSE_DASH)
    for t in _targets(dash):
        assert "Attributes['MetricName']" not in t["query"]


# ---- panels -----------------------------------------------------------------


def test_panel_titles_and_order_match_the_reference():
    dash = jsonnet_eval(BROWSE_DASH)
    assert [p["title"] for p in dash["panels"]] == TITLES


def test_host_counts_queries_all_four_statuses():
    dash = jsonnet_eval(BROWSE_DASH)
    assert _metrics_of(_panel(dash, "Host Counts by Status")) == [
        ELB + "HealthyHostCount",
        ELB + "AnomalousHostCount",
        ELB + "UnHealthyHostCount",
        ELB + "MitigatedHostCount",
    ]


def test_processed_bytes_queries_only_bytes():
    """The reference pasted Grpc/IPv6 request-count targets into this panel —
    request counts on a bytes axis."""
    dash = jsonnet_eval(BROWSE_DASH)
    panel = _panel(dash, "Processed Bytes")
    assert _metrics_of(panel) == [ELB + "ProcessedBytes"]
    assert panel["fieldConfig"]["defaults"]["unit"] == "bytes"


def test_fixed_response_count_queries_only_its_metric():
    dash = jsonnet_eval(BROWSE_DASH)
    assert _metrics_of(_panel(dash, "HTTP_Fixed_Response_Count")) == [
        ELB + "HTTP_Fixed_Response_Count"
    ]


def test_elb_5xx_panel_covers_500_through_504_without_duplicates():
    """The reference queried 502 twice (labelled 502 both times) and never 504."""
    dash = jsonnet_eval(BROWSE_DASH)
    assert _metrics_of(_panel(dash, "ELB 5xx Responses by Code")) == [
        ELB + "HTTPCode_ELB_500_Count",
        ELB + "HTTPCode_ELB_502_Count",
        ELB + "HTTPCode_ELB_503_Count",
        ELB + "HTTPCode_ELB_504_Count",
    ]


def test_response_time_is_in_seconds():
    dash = jsonnet_eval(BROWSE_DASH)
    panel = _panel(dash, "TargetResponseTime")
    assert panel["fieldConfig"]["defaults"]["unit"] == "s"


def test_status_panels_stack_bars():
    dash = jsonnet_eval(BROWSE_DASH)
    for title in ["Host Counts by Status", "DNS by Status", "PeakLCUs",
                  "RuleEvaluations", "Processed Bytes"]:
        custom = _panel(dash, title)["fieldConfig"]["defaults"]["custom"]
        assert custom["drawStyle"] == "bars", title
        assert custom["stacking"]["mode"] == "normal", title


def test_grid_fills_rows_without_overlap():
    dash = jsonnet_eval(BROWSE_DASH)
    cells = set()
    for p in dash["panels"]:
        g = p["gridPos"]
        for x in range(g["x"], g["x"] + g["w"]):
            for y in range(g["y"], g["y"] + g["h"]):
                assert (x, y) not in cells, f"{p['title']} overlaps at {(x, y)}"
                cells.add((x, y))
    assert all(0 <= x < 24 for x, _ in cells)


def test_panel_ids_are_unique():
    dash = jsonnet_eval(BROWSE_DASH)
    ids = [p["id"] for p in dash["panels"]]
    assert len(ids) == len(set(ids))
