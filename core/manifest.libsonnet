// Scout resource manifests.
//
// Every rendered file is one of these. `metadata.name` always equals the
// resource's uid — App Platform treats the name as the identity, and lint
// enforces the equality so a mismatch cannot create a duplicate.
//
// ---------------------------------------------------------------------------
// This file is the ONE place that names Scout's wire identifiers. They are
// fixed by the server's resource API, not chosen by us, so they are declared
// here once and referenced everywhere else — including by the linter and the
// tests, which read them back out rather than restating them.
//
// If you find yourself typing one of these strings anywhere else, import it
// from here instead.
// ---------------------------------------------------------------------------
{
  local m = self,

  // Resource API groups, verified against a live Scout instance.
  apiVersions:: {
    dashboard: 'dashboard.grafana.app/v1beta1',
    folder: 'folder.grafana.app/v1beta1',
    alertRuleGroup: 'alerting.ext.grafana.app/v1alpha1',
  },

  // Annotation carrying a dashboard's folder placement.
  folderAnnotation:: 'grafana.app/folder',

  // The built-in annotations query every dashboard carries. A server-side
  // construct with a reserved uid; we emit it so our render matches what Scout
  // stores, rather than differing on save and showing a permanent diff.
  builtinAnnotationDatasource:: { type: 'grafana', uid: '-- Grafana --' },

  // The Scout SQL datasource plugin id.
  datasourceType:: 'vertamedia-clickhouse-datasource',

  // Expression datasource for alert reduce/threshold stages.
  expressionDatasourceUid:: '__expr__',

  // Reserved uids that are never ours and must not be treated as orphans.
  reservedDatasourceUids:: ['__expr__', '-- Grafana --', 'grafana'],

  dashboard(uid, spec):: {
    apiVersion: m.apiVersions.dashboard,
    kind: 'Dashboard',
    metadata: { name: uid },
    spec: spec,
  },

  folder(uid, title, parentUid=null):: {
    apiVersion: m.apiVersions.folder,
    kind: 'Folder',
    metadata: { name: uid },
    spec: { title: title } + (if parentUid != null then { parent: parentUid } else {}),
  },

  alertRuleGroup(uid, spec):: {
    apiVersion: m.apiVersions.alertRuleGroup,
    kind: 'AlertRuleGroup',
    metadata: { name: uid },
    spec: spec,
  },

  // Where a manifest lands under rendered/<target>/. Kind directories keep the
  // tree navigable and let `push` target one kind when needed.
  path(target, kindDir, name):: target + '/' + kindDir + '/' + name + '.json',
}
