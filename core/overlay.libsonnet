// The preview overlay.
//
// Local dev and merge-request previews are the same machinery pointed at a
// different namespace — one overlay, two callers — so a preview that works
// locally works in CI.
//
// Three rewrites, and the third is a HARD OVERRIDE rather than a default:
//   1. folder      -> Preview / <ns>
//   2. uid + title -> prefixed with <ns>, so two developers cannot collide
//   3. contact points -> ALWAYS the preview contact point
//
// (3) discards whatever the tenant declares. A preview alert must not be able to
// page a real channel even if a template says otherwise. tests/test_overlay.py
// asserts no namespaced manifest references any other contact point, that every
// uid carries the prefix, and that the overlay changes only these fields.
local manifest = import 'manifest.libsonnet';
local naming = import 'naming.libsonnet';

{
  local o = self,

  // Applies to dashboards and alert rule groups only. Datasources, mute timings,
  // and the notification policy tree are shared infrastructure and are never
  // pushed by a preview.
  appliesTo:: ['Dashboard', 'AlertRuleGroup'],

  folderUid(ns):: naming.previewFolderUid(ns),
  folderTitle(ns):: naming.previewFolderTitle(ns),

  apply(doc, ns, previewContactPoint, folderUid)::
    if !std.member(o.appliesTo, doc.kind) then
      error 'overlay must not be applied to kind %s' % doc.kind
    else if doc.kind == 'Dashboard' then
      o.dashboard(doc, ns, folderUid)
    else
      o.alertRuleGroup(doc, ns, previewContactPoint, folderUid),

  dashboard(doc, ns, folderUid)::
    local uid = naming.prefixed(ns, doc.metadata.name);
    doc {
      metadata+: {
        name: uid,
        // The folder annotation must be rewritten too. Without it the dashboard
        // keeps pointing at the real tenant folder and a preview lands next to
        // production assets — which is the whole thing the namespace prevents.
        annotations+: { [manifest.folderAnnotation]: folderUid },
      },
      spec+: {
        uid: uid,
        title: '[%s] %s' % [ns, doc.spec.title],
        tags: std.get(doc.spec, 'tags', []) + ['preview', ns],
      },
    },

  alertRuleGroup(doc, ns, previewContactPoint, folderUid)::
    local uid = naming.prefixed(ns, doc.metadata.name);
    doc {
      metadata+: {
        name: uid,
        // Alert groups carry their folder in spec.folderUid, but the annotation is
        // what a human reads when debugging — leaving it pointing at the real tenant
        // folder would actively mislead.
        annotations+: { [manifest.folderAnnotation]: folderUid },
      },
      spec+: {
        title: '%s-%s' % [ns, doc.spec.title],
        folderUid: folderUid,
        rules: [
          rule {
            uid: naming.prefixed(ns, rule.uid),
            title: '[%s] %s' % [ns, rule.title],
            folderUID: folderUid,
            // The hard override. Not a default — set unconditionally, replacing
            // any tenant contact point the rule arrived with.
            notificationSettings: { receiver: previewContactPoint },
            labels+: { preview: ns },
          }
          for rule in doc.spec.rules
        ],
      },
    },

  // requires()'s other half. A mixin declares the metrics its panels query; a
  // deployment that lacks some of them (a load balancer type that never emits
  // Grpc counters, an engine without ephemeral storage) prunes those targets
  // here instead of shipping permanently-empty panels. Applies to the BUILT
  // dashboard object, before it is wrapped in a manifest.
  //
  // absentMetrics are full metric names; matching is on the quoted name so a
  // prefix cannot prune its longer siblings. Panels without a targets field
  // (rows) pass through; a panel whose every target is pruned is dropped.
  pruneTargets(doc, absentMetrics)::
    // strReplace, not findSubstr: go-jsonnet interprets findSubstr in
    // jsonnet itself, and over kilobyte query strings x targets x metrics it
    // alone cost ~12s of a 13s render (measured 2026-09-01). strReplace is a
    // native builtin; "replacing the needle changes the string" is the same
    // containment test.
    local mentions(query) = std.any([
      std.strReplace(query, "'" + m + "'", '') != query
      for m in absentMetrics
    ] + [false]);
    doc {
      panels: std.foldl(
        function(acc, p)
          if !std.objectHas(p, 'targets') then acc + [p]
          else
            local kept = [t for t in p.targets if !mentions(t.query)];
            if std.length(kept) > 0 then acc + [p { targets: kept }] else acc,
        doc.panels,
        [],
      ),
    },
}
