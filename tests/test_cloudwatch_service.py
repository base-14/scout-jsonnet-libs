"""How a deployment declares the ServiceName its CloudWatch stream lands under.

Some collectors tag every stream metric with one fixed ServiceName; others tag
each metric with its own namespace. The scope carries the scheme so mixins need
no per-deployment edits.
"""

from conftest import jsonnet_eval

CW = "local cw = import 'core/cloudwatch.libsonnet';"
METRIC = "amazonaws.com/AWS/RDS/CPUUtilization"


def test_literal_scheme_wins():
    got = jsonnet_eval(
        CW + f"cw.serviceNameFor({{cloudwatchService:: 'my-collector'}}, '{METRIC}')"
    )
    assert got == "my-collector"


def test_namespace_scheme_derives_from_the_metric():
    got = jsonnet_eval(
        CW + f"cw.serviceNameFor({{cloudwatchService:: 'namespace'}}, '{METRIC}')"
    )
    assert got == "AWS/RDS"


def test_absent_scheme_keeps_the_default():
    got = jsonnet_eval(CW + f"cw.serviceNameFor({{}}, '{METRIC}')")
    assert got == "aws-cloudwatch-stream"


def test_stream_target_threads_the_scheme():
    scope = ("{cloudwatchService:: 'namespace', datasourceUid: 'ds', "
             "database: 'db', envPredicate:: null}")
    got = jsonnet_eval(
        CW + f"cw.streamTarget({scope}, 'A', '{METRIC}', 'max(Sum)', 'x')"
    )
    assert "ServiceName = 'AWS/RDS'" in got["query"]
    assert "aws-cloudwatch-stream" not in got["query"]


def test_dim_variable_threads_the_scheme():
    scope = ("{cloudwatchService:: 'namespace', datasourceUid: 'ds', "
             "database: 'db', envPredicate:: null}")
    got = jsonnet_eval(
        CW + f"cw.dimVariable({scope}, 'v', 'V', 'DBInstanceIdentifier', '{METRIC}')"
    )
    assert "ServiceName = 'AWS/RDS'" in got["query"]
