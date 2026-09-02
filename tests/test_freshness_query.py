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


def test_no_groups_is_single_row_without_sentinel():
    """Ungrouped aggregates return one row even over zero input, so a
    sentinel would DUPLICATE the empty label set — the rule engine rejects
    'duplicate results with labels {}'. Silence coalesces to epoch, i.e. a
    huge lag that fires."""
    sql = _render("[]")
    assert "UNION ALL" not in sql
    assert "GROUP BY" not in sql
    assert "coalesce(max(TimeUnix), toDateTime64(0, 9))" in sql
