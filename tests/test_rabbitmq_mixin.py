"""The rabbitmq mixin: OTel rabbitmq-receiver telemetry as a library dashboard.

Unlike the AWS mixins this one reads native rabbitmq.* metrics from the sum
table, keyed by ServiceName. The reference dashboard it was ported from had
no environment predicate at all and pinned ServiceName with a custom variable
hardcoding one real deployment's name — both replaced here: scoping comes
from the identity contract, and the service axis is an env-scoped query
dropdown.

Two semantic corrections are pinned below. rabbitmq.consumer.count and
rabbitmq.message.current are recorded PER QUEUE (the reference's own Queues
tile counts distinct rabbitmq.queue.name values), so a bare max(Value) shows
the busiest single queue under a title that reads as a total — the port sums
per-queue maxima instead. And two panels titled "Messages published /
routed" actually chart queue_index_write/read_count_details.rate — disk
queue-index activity — so they are retitled to what they measure.
"""

from __future__ import annotations

from conftest import jsonnet_eval

E = (
    "local mq = import 'mixins/rabbitmq.libsonnet'; "
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

BROWSE_DASH = E + f"mq.dashboards()[0].build({{ scope: {BROWSE} }})"
SCOPED_DASH = E + f"mq.dashboards()[0].build({{ scope: {SCOPED} }})"

QUEUE_ATTR = "ResourceAttributes['rabbitmq.queue.name']"
NODE_ATTR = "ResourceAttributes['rabbitmq.node.name']"

STATS = ["Queues", "Consumers", "Nodes", "Unacknowledged Messages",
         "Ready Messages", "Channels"]

# row title -> titles of the panels nested inside it (rows are collapsed)
ROWS = {
    "Nodes": ["Memory Usage", "Free disk"],
    "Queued Messages": ["Messages ready to be delivered to consumers",
                        "Messages pending consumer acknowledgement"],
    "Incoming Messages": ["Queue index writes / s", "Queue index reads / s"],
    "Queues": ["Queues created / s", "Queues deleted / s", "Queues declared / s"],
    "Channels": ["Channels opened / s", "Channels closed / s"],
    "Connections": ["Connections opened / s", "Connections closed / s"],
}


def _all_panels(dash):
    """Top-level panels plus the members nested inside collapsed rows."""
    out = []
    for p in dash["panels"]:
        out.append(p)
        out.extend(p.get("panels", []))
    return out


def _targets(dash):
    return [t for panel in _all_panels(dash) for t in panel.get("targets", [])]


def _panel(dash, title, type_=None):
    return next(
        p for p in _all_panels(dash)
        if p["title"] == title and (type_ is None or p["type"] == type_)
    )


def _metrics_of(panel):
    return [
        line.split("'")[1]
        for t in panel.get("targets", [])
        for line in t["query"].split("\n")
        if line.strip().startswith("AND MetricName")
    ]


# ---- the mixin contract ----------------------------------------------------


def test_mixin_exports_the_contract():
    assert jsonnet_eval(E + "mq.name") == "rabbitmq"
    assert jsonnet_eval(E + "mq.alerts()") == []


def test_requires_covers_every_queried_metric():
    required = set(jsonnet_eval(E + "mq.requires().metrics"))
    dash = jsonnet_eval(BROWSE_DASH)
    queried = {m for panel in _all_panels(dash) for m in _metrics_of(panel)}
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


def test_every_query_filters_the_service_selection():
    dash = jsonnet_eval(BROWSE_DASH)
    for t in _targets(dash):
        assert "$conditionalTest" not in t["query"]
        assert "ServiceName IN (${service:singlequote})" in t["query"]


# ---- variables --------------------------------------------------------------


def test_service_is_a_query_variable_not_a_hardcoded_name():
    """The reference shipped a custom variable whose one value was a real
    deployment's service name — unusable as a library and barred from this
    repo by the fixtures policy."""
    dash = jsonnet_eval(BROWSE_DASH)
    v = next(v for v in dash["templating"]["list"] if v["name"] == "service")
    assert v["type"] == "query"
    assert v["multi"] is True
    assert v["includeAll"] is True
    assert v["allValue"] is None
    assert "SELECT DISTINCT ServiceName" in v["query"]
    assert "MetricName = 'rabbitmq.message.current'" in v["query"]
    assert "app.otel_metrics_sum" in v["query"]


def test_service_options_stay_inside_the_scope():
    for expr, env_pred in [
        (BROWSE_DASH, "IN (${env:singlequote})"),
        (SCOPED_DASH, "= 'staging'"),
    ]:
        dash = jsonnet_eval(expr)
        v = next(v for v in dash["templating"]["list"] if v["name"] == "service")
        assert "ResourceAttributes['environment'] " + env_pred in v["query"]


def test_browse_variables_are_scope_env_plus_service():
    dash = jsonnet_eval(BROWSE_DASH)
    assert [v["name"] for v in dash["templating"]["list"]] == ["env", "service"]


def test_no_variable_carries_baked_in_options():
    """The reference pinned the service axis with a custom variable whose one
    option was a real deployment's name. Structurally: every variable must be
    query-driven with nothing pre-baked, so no literal deployment identifier
    can survive a port. (The name itself is checked by SCOUT_DENY_EXTRA in
    internal CI — never by this public repo, per test_no_customer_data.)"""
    for expr in [BROWSE_DASH, SCOPED_DASH]:
        for v in jsonnet_eval(expr)["templating"]["list"]:
            assert v["type"] == "query", v["name"]
            assert v["options"] == [], v["name"]
            assert v["current"] == {}, v["name"]


# ---- the stat tiles ---------------------------------------------------------


def test_stat_tiles_are_stats_in_the_reference_order():
    dash = jsonnet_eval(BROWSE_DASH)
    stats = [p["title"] for p in dash["panels"] if p["type"] == "stat"]
    assert stats == STATS


def test_per_queue_metrics_total_across_queues():
    """max(Value) over per-queue series is the busiest queue, not a total.
    The port takes each queue's max within the bucket, then sums queues."""
    dash = jsonnet_eval(BROWSE_DASH)
    for title in ["Consumers", "Unacknowledged Messages", "Ready Messages"]:
        (t,) = _panel(dash, title, "stat")["targets"]
        assert QUEUE_ATTR + " AS queue" in t["query"], title
        assert "GROUP BY t, queue" in t["query"], title
        assert "sum(v)" in t["query"], title


def test_message_state_tiles_filter_their_state():
    dash = jsonnet_eval(BROWSE_DASH)
    for title, state in [
        ("Unacknowledged Messages", "unacknowledged"),
        ("Ready Messages", "ready"),
    ]:
        (t,) = _panel(dash, title, "stat")["targets"]
        assert f"Attributes['state'] = '{state}'" in t["query"], title


def test_inventory_tiles_count_distinct_resources():
    dash = jsonnet_eval(BROWSE_DASH)
    (t,) = _panel(dash, "Queues", "stat")["targets"]
    assert f"count(DISTINCT {QUEUE_ATTR})" in t["query"]
    (t,) = _panel(dash, "Nodes", "stat")["targets"]
    assert f"count(DISTINCT {NODE_ATTR})" in t["query"]


# ---- rows and nested panels -------------------------------------------------


def test_rows_are_collapsed_and_nest_their_members():
    """A collapsed row carries its members in its own `panels`; leaving them
    as siblings would make them vanish from the UI without an error."""
    dash = jsonnet_eval(BROWSE_DASH)
    rows = [p for p in dash["panels"] if p["type"] == "row"]
    assert {r["title"]: [m["title"] for m in r["panels"]] for r in rows} == ROWS
    for r in rows:
        assert r["collapsed"] is True


def test_queue_index_panels_are_titled_for_what_they_measure():
    dash = jsonnet_eval(BROWSE_DASH)
    writes = _panel(dash, "Queue index writes / s")
    reads = _panel(dash, "Queue index reads / s")
    assert _metrics_of(writes) == ["rabbitmq.node.queue_index_write_count_details.rate"]
    assert _metrics_of(reads) == ["rabbitmq.node.queue_index_read_count_details.rate"]
    for stale in ["Messages published / s", "Messages routed to queues / s"]:
        assert not any(p["title"] == stale for p in _all_panels(dash))


def test_node_panels_split_per_node():
    dash = jsonnet_eval(BROWSE_DASH)
    for title in ["Memory Usage", "Free disk", "Queue index writes / s",
                  "Queues created / s", "Channels opened / s",
                  "Connections opened / s"]:
        for t in _panel(dash, title)["targets"]:
            assert NODE_ATTR + " AS node" in t["query"], title


def test_memory_is_bytes_not_short():
    """rabbitmq.node.mem_used reports bytes; the reference labelled the panel
    `short` while its disk sibling correctly used bytes."""
    dash = jsonnet_eval(BROWSE_DASH)
    assert _panel(dash, "Memory Usage")["fieldConfig"]["defaults"]["unit"] == "bytes"
    assert _panel(dash, "Free disk")["fieldConfig"]["defaults"]["unit"] == "bytes"


# ---- query shape ------------------------------------------------------------


def test_queries_read_the_sum_table():
    dash = jsonnet_eval(BROWSE_DASH)
    for t in _targets(dash):
        assert t["table"] == "otel_metrics_sum"


def test_panel_ids_are_unique_including_nested():
    dash = jsonnet_eval(BROWSE_DASH)
    ids = [p["id"] for p in _all_panels(dash)]
    assert len(ids) == len(set(ids))
