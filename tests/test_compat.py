"""One declared version; every derived constant follows from it.

schemaVersion, pluginVersion and the resource apiVersions were three
independent literals kept in agreement by hand. All of them follow from the
upstream version a Scout release is built on.
"""

from __future__ import annotations

import pytest

from conftest import jsonnet_eval

C = "local c = import 'core/compat.libsonnet'; "


def test_known_version_resolves_every_constant():
    got = jsonnet_eval(C + "c.forVersion('1.4')")
    assert got["schemaVersion"] == 42
    assert got["pluginVersion"] == "12.4.3"
    assert got["apiVersions"]["dashboard"] == "dashboard.grafana.app/v1beta1"
    assert got["apiVersions"]["folder"] == "folder.grafana.app/v1beta1"
    assert got["apiVersions"]["alertRuleGroup"] == "alerting.ext.grafana.app/v1alpha1"
    assert got["jsonnet"] == "go-jsonnet 0.20.0"


def test_unknown_version_names_both_sides():
    with pytest.raises(Exception) as exc:
        jsonnet_eval(C + "c.forVersion('9.9')")
    msg = str(exc.value)
    assert "9.9" in msg
    assert "1.4" in msg, "the error must list what this release supports"


def test_binding_overrides_the_module_constants():
    """withCompat is how a consumer pins a version without editing the library."""
    got = jsonnet_eval(
        "local p = import 'core/panels.libsonnet';"
        " local c = import 'core/compat.libsonnet';"
        " local bound = p.withCompat(c.forVersion('1.4'));"
        " { schemaVersion: bound.schemaVersion, pluginVersion: bound.pluginVersion }"
    )
    assert got == {"schemaVersion": 42, "pluginVersion": "12.4.3"}

    api = jsonnet_eval(
        "local m = import 'core/manifest.libsonnet';"
        " local c = import 'core/compat.libsonnet';"
        " m.withCompat(c.forVersion('1.4')).apiVersions.dashboard"
    )
    assert api == "dashboard.grafana.app/v1beta1"
