"""core/sql.libsonnet's query shapes, exercised directly.

The counter macros ($perSecond, $increase, and the *Columns variants) REPLACE
the SELECT…FROM head — they must lead the query. Embedded as a value expression
they produce valid SQL that returns nothing. Testing the builders directly
catches that without needing a template to render them.
"""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def sql(expr: str) -> str:
    out = subprocess.run(
        ["jsonnet", "-J", str(ROOT), "-e",
         f"local ch = import 'core/sql.libsonnet'; {expr}"],
        check=True, cwd=ROOT, capture_output=True, text=True,
    )
    return json.loads(out.stdout)


PREDS = "[\"MetricName = 'apid_request_received_total'\", "\
        "\"ResourceAttributes['environment'] IN (${tenant:singlequote})\"]"


def test_per_second_macro_leads_the_query():
    q = sql(f"ch.perSecondQuery('app_stg', 'otel_metrics_sum', {PREDS})")
    assert q.splitlines()[0] == "$perSecond(Value)"
    assert "SELECT" not in q, "the macro replaces the SELECT head; adding one breaks it"


def test_increase_macro_leads_the_query():
    q = sql(f"ch.increaseQuery('app_stg', 'otel_metrics_sum', {PREDS})")
    assert q.splitlines()[0] == "$increase(Value)"


def test_counter_queries_carry_the_time_filter():
    """Without $timeFilter the query scans every partition."""
    for builder in ("perSecondQuery", "increaseQuery"):
        q = sql(f"ch.{builder}('app_stg', 'otel_metrics_sum', {PREDS})")
        assert "$timeFilter" in q, builder


def test_columns_variants_take_one_key_and_alias_it_series():
    q = sql(
        "ch.perSecondColumnsQuery('app_stg', 'otel_metrics_sum', "
        f"\"ResourceAttributes['environment']\", {PREDS})"
    )
    assert q.splitlines()[0] == (
        "$perSecondColumns(ResourceAttributes['environment'] AS series, Value)"
    )


def test_series_key_folds_dimensions_into_one_expression():
    """The *Columns macros accept exactly one key expression."""
    assert sql("ch.seriesKey([\"a\"])") == "a"
    assert sql("ch.seriesKey([\"a\", \"b\"])") == "concat(a, ' / ', b)"


def test_columns_query_omits_the_time_filter():
    """$columns injects its own; a second one duplicates it."""
    q = sql(
        "ch.columnsQuery('app_stg', 'otel_metrics_sum', "
        f"\"Attributes['version']\", 'count() AS containers', {PREDS})"
    )
    assert "$timeFilter" not in q
    assert q.splitlines()[0] == "$columns(Attributes['version'] AS series, count() AS containers)"
    assert "GROUP BY t, series" in q


def leads_with_counter_macro(sql: str) -> bool:
    """Mirrors the exemption clause in test_queries.py's
    test_no_raw_value_from_cumulative_tables: the macro must be the first
    non-empty line, not merely present anywhere in the query.
    """
    first_line = next((line.strip() for line in sql.splitlines() if line.strip()), "")
    return bool(re.match(r"\$(perSecond|increase)(Columns)?\(", first_line))


def test_cumulative_guard_admits_columns_variants_and_still_rejects_raw_value():
    """The guard in test_queries.py must exempt $perSecondColumns but not max(Value)."""
    assert leads_with_counter_macro("$perSecondColumns(k AS series, Value)\nFROM db.t\nWHERE $timeFilter")
    assert leads_with_counter_macro("$increaseColumns(k AS series, Value)\nFROM db.t\nWHERE $timeFilter")
    assert leads_with_counter_macro("$perSecond(Value)\nFROM db.t\nWHERE $timeFilter")
    assert not leads_with_counter_macro("SELECT $timeSeries AS t, max(Value) AS v FROM db.t")


def is_flagged_as_raw_value(sql: str) -> bool:
    """Mirrors the full guard condition in test_no_raw_value_from_cumulative_tables:
    a bare Value reference is a problem unless a counter macro leads the query.
    """
    return bool(re.search(r"(?<![\w$(])Value\b", sql)) and not leads_with_counter_macro(sql)


def test_cumulative_guard_rejects_a_bare_value_next_to_a_decoy_mid_query_macro():
    """Only a LEADING counter macro exempts a query from the raw-Value rule.

    A macro appearing anywhere else is a value-expression misuse, not a
    query-shape builder's output, and it must not launder a genuine bare Value
    alongside it. Matching the macro anywhere in the query would exempt the
    whole thing.
    """
    decoy = (
        "SELECT $timeSeries AS t, Value AS v, foo($perSecond(bar)) AS x\n"
        "FROM app_stg.otel_metrics_sum\n"
        "WHERE $timeFilter\n"
        "GROUP BY t"
    )
    old_exempt = re.search(r"\$(perSecond|increase)(Columns)?\(", decoy)
    assert old_exempt, "sanity: the macro does appear somewhere in the query"
    assert is_flagged_as_raw_value(decoy), (
        "a bare Value must not be exempted just because a counter macro appears "
        "elsewhere, non-leading, in the same query"
    )


CUMULATIVE_TABLES = {"otel_metrics_sum"}


def is_cumulative_table_query(sql: str) -> bool:
    """A table name must match as a whole word, not merely as a substring.

    Otherwise otel_metrics_summary — the quantile-summary table — is caught by
    a check meant for otel_metrics_sum, the cumulative-counter table.
    """
    return any(re.search(rf"\b{table}\b", sql) for table in CUMULATIVE_TABLES)


def test_cumulative_table_match_excludes_the_summary_table():
    """A summary-table quantile read must not be treated as a cumulative-table
    read just because 'otel_metrics_sum' is a textual prefix of
    'otel_metrics_summary'. ValueAtQuantiles.Value contains a bare 'Value'
    token, so the table match has to be on a word boundary."""
    q = (
        "SELECT $timeSeries AS t, "
        "max(arrayElement(ValueAtQuantiles.Value, indexOf(ValueAtQuantiles.Quantile, 0.99))) AS v\n"
        "FROM app_stg.otel_metrics_summary\n"
        "WHERE $timeFilter\n"
        "GROUP BY t"
    )
    assert is_flagged_as_raw_value(q), "sanity: the query does contain a bare Value token"
    assert not is_cumulative_table_query(q), (
        "otel_metrics_summary must not match the otel_metrics_sum table check"
    )


def test_cumulative_table_match_still_catches_the_real_sum_table():
    """A genuine bare Value read from otel_metrics_sum must still be caught."""
    q = (
        "SELECT $timeSeries AS t, Value AS v\n"
        "FROM app_stg.otel_metrics_sum\n"
        "WHERE $timeFilter\n"
        "GROUP BY t"
    )
    assert is_cumulative_table_query(q)
    assert is_flagged_as_raw_value(q)


SUMMARY_PREDS = "[\"MetricName = 'apid_response_latency_summary'\", "\
                "\"ResourceAttributes['environment'] IN (${tenant:singlequote})\"]"


def test_summary_average_lags_per_instance():
    """Differencing after aggregation mixes unrelated counters across containers."""
    q = sql(
        "ch.summaryAverageQuery('app_stg', 'otel_metrics_summary', "
        f"\"ResourceAttributes['environment']\", 'avg_seconds', {SUMMARY_PREDS})"
    )
    assert "PARTITION BY series, instance" in q, (
        "the delta must be per instance, or a restart corrupts the ratio"
    )
    assert "service.instance.id" in q


def test_summary_average_is_grouped_and_time_filtered():
    q = sql(
        "ch.summaryAverageQuery('app_stg', 'otel_metrics_summary', "
        f"\"ResourceAttributes['environment']\", 'avg_seconds', {SUMMARY_PREDS})"
    )
    assert "$timeFilter" in q
    assert "GROUP BY t, series" in q
    assert "$timeSeries AS t" in q


def test_summary_average_discards_counter_resets():
    """A restart makes the lagged delta negative; a plausible wrong line is worse
    than a gap."""
    q = sql(
        "ch.summaryAverageQuery('app_stg', 'otel_metrics_summary', "
        f"\"ResourceAttributes['environment']\", 'avg_seconds', {SUMMARY_PREDS})"
    )
    assert "WHERE d_count > 0" in q
