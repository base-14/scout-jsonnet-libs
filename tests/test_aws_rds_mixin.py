"""The aws-rds mixin: CloudWatch RDS telemetry as a library dashboard.

Ported from a hand-built reference dashboard. Beyond the usual correction —
scoping through the identity contract instead of a hand-written predicate —
these tests pin three unit fixes checked against the CloudWatch metric
reference (CommitLatency is milliseconds, OldestReplicationSlotLag is
megabytes, WriteThroughput is bytes/second; the reference labelled all three
as seconds) and one query fix: the by-cluster CPU panel filtered on
DBInstanceIdentifier while splitting on DBClusterIdentifier, which only ever
returned cluster rows because $conditionalTest dropped the filter when
nothing was selected.
"""

from __future__ import annotations

from conftest import jsonnet_eval

E = (
    "local rds = import 'mixins/aws_rds.libsonnet'; "
    "local sc = import 'identity/scopes.libsonnet'; "
    "local p = import 'identity/profiles/init.libsonnet'; "
)

BROWSE = (
    "sc.browse({ database: 'app', datasourceUid: 'ds-app', "
    "envPrefixes: ['staging', 'prod'] }, 'go_goroutines', p.environmentOnly)"
)
SCOPED = (
    "sc.scoped({ database: 'app', datasourceUid: 'ds-app', envLabel: 'staging', "
    "tenant: null, environment: 'staging' }, p.environmentOnly)"
)

BROWSE_DASH = E + f"rds.dashboards()[0].build({{ scope: {BROWSE} }})"
SCOPED_DASH = E + f"rds.dashboards()[0].build({{ scope: {SCOPED} }})"

RDS = "amazonaws.com/AWS/RDS/"

INSTANCE_DIM = "simpleJSONExtractString(Attributes['Dimensions'], 'DBInstanceIdentifier')"
CLUSTER_DIM = "simpleJSONExtractString(Attributes['Dimensions'], 'DBClusterIdentifier')"

# (type, title) in render order: four headline panels, then six titled rows.
LAYOUT = [
    ("timeseries", "Commit Latency"),
    ("timeseries", "Engine Uptime"),
    ("timeseries", "Deadlocks"),
    ("timeseries", "DB Connections"),
    ("row", "Throughputs"),
    ("timeseries", "Commit Throughput (per second)"),
    ("timeseries", "Network Throughput (bytes per second)"),
    ("timeseries", "Temp Storage Throughput (bytes per second)"),
    ("timeseries", "Storage Network Throughput (bytes per second)"),
    ("row", "Lags and Latencies"),
    ("timeseries", "Checkpoint Lag"),
    ("timeseries", "Aurora Replica Lag"),
    ("timeseries", "Oldest Replication Slot Lag"),
    ("timeseries", "RDS To Aurora PostgreSQL Replica Lag"),
    ("row", "I/O"),
    ("timeseries", "Read IOPS"),
    ("timeseries", "Write IOPS"),
    ("timeseries", "Read Latency"),
    ("timeseries", "Write Latency"),
    ("timeseries", "Read Throughput (per second)"),
    ("timeseries", "Write Throughput (per second)"),
    ("timeseries", "Disk Queue Depth"),
    ("timeseries", "Buffer Cache Hit Ratio"),
    ("row", "Storage"),
    ("timeseries", "Free Storage Space"),
    ("timeseries", "Free Local Storage Space"),
    ("row", "Memory"),
    ("timeseries", "Freeable Memory"),
    ("row", "CPU Utilization"),
    ("timeseries", "CPU Utilization by Instance"),
    ("timeseries", "DB Load per VCPU"),
    ("timeseries", "CPU Utilization by Cluster"),
    ("timeseries", "DB Load Avg"),
]


def _targets(dash):
    return [t for panel in dash["panels"] for t in panel.get("targets", [])]


def _panel(dash, title):
    return next(p for p in dash["panels"] if p["title"] == title)


def _metrics_of(panel):
    return [
        line.split("'")[1]
        for t in panel.get("targets", [])
        for line in t["query"].split("\n")
        if line.strip().startswith("AND MetricName")
    ]


# ---- the mixin contract ----------------------------------------------------


def test_mixin_exports_the_contract():
    assert jsonnet_eval(E + "rds.name") == "aws-rds"
    assert jsonnet_eval(E + "rds.alerts()") == []


def test_requires_covers_every_queried_metric():
    required = set(jsonnet_eval(E + "rds.requires().metrics"))
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


def test_instance_filter_is_plain_in_everywhere_but_the_cluster_panel():
    """$conditionalTest would widen the result on an empty selection; and the
    cluster panel must not filter on an instance dimension its datapoints do
    not carry."""
    dash = jsonnet_eval(BROWSE_DASH)
    for panel in dash["panels"]:
        for t in panel.get("targets", []):
            assert "$conditionalTest" not in t["query"]
            if panel["title"] == "CPU Utilization by Cluster":
                assert "dbInstance" not in t["query"]
            else:
                assert INSTANCE_DIM + " IN (${dbInstance:singlequote})" in t["query"]


def test_cluster_panel_splits_and_gates_on_the_cluster_dimension():
    """Stream datapoints exist per dimension SET: rows carrying
    DBClusterIdentifier carry no DBInstanceIdentifier and vice versa, and a
    missing key extracts as ''. Splitting on the cluster id therefore requires
    selecting the rows that have one."""
    dash = jsonnet_eval(BROWSE_DASH)
    (t,) = _panel(dash, "CPU Utilization by Cluster")["targets"]
    assert CLUSTER_DIM + " AS series" in t["query"]
    assert "JSONHas(Attributes['Dimensions'], 'DBClusterIdentifier')" in t["query"]


# ---- variables --------------------------------------------------------------


def test_browse_variables_are_scope_env_plus_dbinstance():
    dash = jsonnet_eval(BROWSE_DASH)
    assert [v["name"] for v in dash["templating"]["list"]] == ["env", "dbInstance"]


def test_scoped_still_offers_the_dbinstance_dropdown():
    dash = jsonnet_eval(SCOPED_DASH)
    assert [v["name"] for v in dash["templating"]["list"]] == ["dbInstance"]


def test_dbinstance_variable_is_env_filtered_and_gated_on_its_dimension():
    for expr, env_pred in [
        (BROWSE_DASH, "IN (${env:singlequote})"),
        (SCOPED_DASH, "= 'staging'"),
    ]:
        dash = jsonnet_eval(expr)
        v = next(v for v in dash["templating"]["list"] if v["name"] == "dbInstance")
        assert v["multi"] is True
        assert v["includeAll"] is True
        assert v["allValue"] is None
        assert "ResourceAttributes['environment'] " + env_pred in v["query"]
        assert f"MetricName = '{RDS}CPUUtilization'" in v["query"]
        assert "JSONHas(Attributes['Dimensions'], 'DBInstanceIdentifier')" in v["query"]
        assert "app.otel_metrics_summary" in v["query"]


# ---- query shape ------------------------------------------------------------


def test_queries_read_the_summary_table_the_stream_writes_to():
    dash = jsonnet_eval(BROWSE_DASH)
    for t in _targets(dash):
        assert t["table"] == "otel_metrics_summary"
        assert "ServiceName = 'aws-cloudwatch-stream'" in t["query"]


def test_reference_aggregations_are_preserved():
    """The reference mixes max (latencies, lags, throughput peaks) and avg
    (gauges) deliberately — not a normalisation target."""
    dash = jsonnet_eval(BROWSE_DASH)
    for title, agg in [
        ("Commit Latency", "max(Sum)"),
        ("Checkpoint Lag", "max(Sum)"),
        ("Network Throughput (bytes per second)", "max(Sum)"),
        ("DB Connections", "avg(Sum)"),
        ("Read IOPS", "avg(Sum)"),
        ("CPU Utilization by Instance", "avg(Sum)"),
    ]:
        for t in _panel(dash, title)["targets"]:
            assert agg in t["query"], title


# ---- panels -----------------------------------------------------------------


def test_layout_matches_the_reference():
    dash = jsonnet_eval(BROWSE_DASH)
    assert [(p["type"], p["title"]) for p in dash["panels"]] == LAYOUT


def test_rows_are_expanded_with_members_as_siblings():
    """A collapsed row nests its members; an expanded one leaves them as
    siblings. Getting it backwards hides the panels without an error."""
    dash = jsonnet_eval(BROWSE_DASH)
    rows = [p for p in dash["panels"] if p["type"] == "row"]
    assert len(rows) == 6
    for row in rows:
        assert row["collapsed"] is False
        assert row["panels"] == []
        assert row["gridPos"]["w"] == 24 and row["gridPos"]["h"] == 1


def test_units_are_corrected_against_the_cloudwatch_reference():
    dash = jsonnet_eval(BROWSE_DASH)
    for title, unit in [
        ("Commit Latency", "ms"),  # reference said s; CommitLatency is milliseconds
        ("Oldest Replication Slot Lag", "decmbytes"),  # reference said s; it is megabytes of WAL
        ("Write Throughput (per second)", "bytes"),  # reference said s; it is bytes/second
        ("Read Throughput (per second)", "bytes"),
        ("Engine Uptime", "s"),
        ("Aurora Replica Lag", "ms"),
        ("Buffer Cache Hit Ratio", "percent"),
        ("CPU Utilization by Instance", "percent"),
        ("Free Storage Space", "bytes"),
        ("Freeable Memory", "bytes"),
    ]:
        assert _panel(dash, title)["fieldConfig"]["defaults"]["unit"] == unit, title


def test_multi_metric_panels_carry_prefixed_series():
    dash = jsonnet_eval(BROWSE_DASH)
    free = _panel(dash, "Free Local Storage Space")
    assert _metrics_of(free) == [RDS + "FreeLocalStorage", RDS + "FreeEphemeralStorage"]
    assert "concat('Free Local - '" in free["targets"][0]["query"]
    assert "concat('Free Ephemeral - '" in free["targets"][1]["query"]

    load = _panel(dash, "DB Load Avg")
    assert _metrics_of(load) == [RDS + "DBLoad", RDS + "DBLoadCPU", RDS + "DBLoadNonCPU"]

    # Single-metric panels split on the bare instance name — no noise prefix.
    (t,) = _panel(dash, "DB Load per VCPU")["targets"]
    assert "concat(" not in t["query"]
    assert INSTANCE_DIM + " AS series" in t["query"]


def test_deadlocks_render_as_bars():
    dash = jsonnet_eval(BROWSE_DASH)
    custom = _panel(dash, "Deadlocks")["fieldConfig"]["defaults"]["custom"]
    assert custom["drawStyle"] == "bars"
    assert custom["stacking"]["mode"] == "none"


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
