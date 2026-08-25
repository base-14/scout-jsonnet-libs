// Scout version -> the constants a render must match.
//
// A deployment declares exactly one version. schemaVersion, pluginVersion and
// the resource apiVersions all follow from the upstream version a Scout
// release is built on, rather than being three literals kept in agreement by
// hand.
//
// Getting them wrong does not error. Scout normalises dashboards when it saves
// them, so a render that disagrees produces a permanent diff against the server
// on every asset — and once every diff is noise, nobody reads them.
{
  local c = self,

  versions:: {
    '1.4': {
      upstream: '12.4.3',
      schemaVersion: 42,
      pluginVersion: '12.4.3',
      apiVersions: {
        dashboard: 'dashboard.grafana.app/v1beta1',
        folder: 'folder.grafana.app/v1beta1',
        alertRuleGroup: 'alerting.ext.grafana.app/v1alpha1',
      },
      // The jsonnet implementation this release was tested against.
      // Implementations disagree on float formatting, so this is not advisory.
      jsonnet: 'go-jsonnet 0.20.0',
    },
  },

  supported:: std.objectFields(c.versions),

  // A library release cannot know about Scout versions published after it. A
  // deployment ahead of its vendored library fails here and upgrades, rather
  // than rendering against constants that are quietly wrong.
  forVersion(scoutVersion)::
    if !std.objectHas(c.versions, scoutVersion) then
      error 'scout version %s is not supported by this scout-jsonnet-libs release. Supported: %s. Upgrade the library, or correct the declared version.'
            % [scoutVersion, std.join(', ', c.supported)]
    else c.versions[scoutVersion],
}
