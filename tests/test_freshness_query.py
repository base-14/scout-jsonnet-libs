"""freshnessSeriesQuery: single-bucket wide time series for absence alerts."""

from conftest import jsonnet_eval


def _render(group_by):
    return jsonnet_eval(
        """
        local ch = import 'core/sql.libsonnet';
        ch.freshnessSeriesQuery('db', 'tbl', ["MetricName = 'm'"], %s)
        """
        % group_by
    )


def test_emits_time_column_labels_then_lag():
    sql = _render("[\"x AS tenant\", \"'c' AS check\"]")
    head = sql.split("\n")[0]
    assert head.startswith("SELECT toUnixTimestamp(toStartOfMinute(now())) * 1000 AS t")
    assert head.index("AS t") < head.index("AS tenant") < head.index("AS check")
    assert head.rstrip().endswith("AS lag_seconds")


def test_groups_by_time_and_label_aliases():
    sql = _render("[\"x AS tenant\", \"'c' AS check\"]")
    assert "GROUP BY t, tenant, check" in sql


def test_sentinel_matches_column_count():
    sql = _render("[\"x AS tenant\", \"'c' AS check\"]")
    assert sql.strip().endswith("UNION ALL SELECT toUnixTimestamp(toStartOfMinute(now())) * 1000, '__none__', '__none__', 0")


def test_no_groups_still_shaped():
    sql = _render("[]")
    assert "GROUP BY t\n" in sql
    assert sql.strip().endswith("UNION ALL SELECT toUnixTimestamp(toStartOfMinute(now())) * 1000, 0")
