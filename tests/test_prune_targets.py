"""pruneTargets: requires()'s other half.

A mixin declares the metrics it queries; a deployment that lacks some of them
prunes those targets instead of shipping permanently-empty panels.
"""

from conftest import jsonnet_eval

PRELUDE = "local o = import 'core/overlay.libsonnet';"

DOC = """{
  title: 'd',
  panels: [
    { id: 1, title: 'both', targets: [
      { refId: 'A', query: "MetricName = 'amazonaws.com/AWS/X/Kept'" },
      { refId: 'B', query: "MetricName = 'amazonaws.com/AWS/X/Gone'" },
    ] },
    { id: 2, title: 'row only', type: 'row' },
    { id: 3, title: 'all gone', targets: [
      { refId: 'A', query: "MetricName = 'amazonaws.com/AWS/X/Gone'" },
    ] },
  ],
}"""


def prune(absent):
    return jsonnet_eval(PRELUDE + f"o.pruneTargets({DOC}, {absent})")


def test_absent_target_removed_survivor_kept():
    got = prune("['amazonaws.com/AWS/X/Gone']")
    panel = [p for p in got["panels"] if p["id"] == 1][0]
    assert [t["refId"] for t in panel["targets"]] == ["A"]


def test_panel_with_no_surviving_targets_is_dropped():
    got = prune("['amazonaws.com/AWS/X/Gone']")
    assert [p["id"] for p in got["panels"]] == [1, 2]


def test_row_panels_survive_untouched():
    got = prune("['amazonaws.com/AWS/X/Gone']")
    assert any(p.get("type") == "row" for p in got["panels"])


def test_empty_absent_list_is_a_no_op():
    got = prune("[]")
    assert [p["id"] for p in got["panels"]] == [1, 2, 3]
    assert len(got["panels"][0]["targets"]) == 2


def test_matching_is_on_the_whole_quoted_name():
    # 'Gone' must not prune 'GoneFishing'
    doc = """{
      title: 'd',
      panels: [{ id: 1, targets: [
        { refId: 'A', query: "MetricName = 'amazonaws.com/AWS/X/GoneFishing'" },
      ] }],
    }"""
    got = jsonnet_eval(
        PRELUDE + f"o.pruneTargets({doc}, ['amazonaws.com/AWS/X/Gone'])"
    )
    assert len(got["panels"][0]["targets"]) == 1
