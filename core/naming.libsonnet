// Deterministic uids, titles, and folders.
//
// Never auto-generated: a stable uid is what makes push idempotent and diffs
// readable. An auto-generated uid would make every re-render look like
// delete-and-recreate.
//
// Scout caps uids at 40 characters. `prod-<longtenant>-<template>` can exceed
// that, so truncation is deterministic and lint enforces post-truncation
// uniqueness — silent collision would mean one asset overwriting another.
{
  local n = self,

  maxUidLen:: 40,

  // Truncate from the middle, keeping both ends recognisable and appending a
  // short digest so two long names that share a prefix cannot collide.
  //
  // std.md5 is the only hash in the jsonnet stdlib. It is used here as a short
  // collision-resistant tag, not for anything security-related.
  clamp(s)::
    if std.length(s) <= n.maxUidLen then s
    else
      local digest = std.substr(std.md5(s), 0, 6);
      local keep = n.maxUidLen - std.length(digest) - 1;
      std.substr(s, 0, keep) + '-' + digest,

  slug(s):: std.asciiLower(std.strReplace(std.strReplace(s, '_', '-'), ' ', '-')),

  // ---- scoped: one asset per (tenant, environment) instance ----------------
  scopedFolderUid(envLabel):: n.clamp('t-' + n.slug(envLabel)),
  // With no tenant axis the environment is the whole identity, so a `Foo / bar`
  // title would read as a missing value rather than an absent dimension.
  scopedFolderTitle(tenant, environment)::
    if tenant == null then n.titleCase(environment)
    else n.titleCase(tenant) + ' / ' + environment,
  scopedUid(envLabel, template):: n.clamp(n.slug(envLabel) + '-' + n.slug(template)),

  // ---- browse: one asset per (target, database) scope ----------------------
  browseFolderUid(database):: n.clamp('browse-' + n.slug(database)),
  browseFolderTitle(database):: 'Browse / ' + database,
  browseUid(database, template):: n.clamp('browse-' + n.slug(database) + '-' + n.slug(template)),

  // ---- global: tenant-agnostic --------------------------------------------
  globalFolderUid:: 'platform',
  globalFolderTitle:: 'Platform',
  globalUid(template, database=null)::
    n.clamp('platform-' + n.slug(template) + (if database == null then '' else '-' + n.slug(database))),

  // ---- preview namespaces --------------------------------------------------
  //
  // Local dev and merge-request previews are the same machinery with a different
  // namespace string, so a preview that works locally works in CI.
  // The namespace IS the folder. Previews land in a folder an admin has already
  // provisioned for the developer (or for CI), so the repo must use its real name
  // rather than deriving a decorated one that does not exist.
  previewFolderUid(ns):: n.clamp(n.slug(ns)),
  previewFolderTitle(ns):: ns,
  prefixed(ns, uid):: n.clamp(n.slug(ns) + '-' + uid),

  titleCase(s)::
    if std.length(s) == 0 then s
    else std.asciiUpper(std.substr(s, 0, 1)) + std.substr(s, 1, std.length(s) - 1),
}
