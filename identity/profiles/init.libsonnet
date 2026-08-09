// The built-in identity profiles.
//
// A deployment whose scheme matches none of these supplies its own object
// implementing the same contract. tests/test_identity_conformance.py is
// exported for exactly that purpose — run it against your profile, because a
// profile missing a member renders a query with no environment predicate
// rather than failing.
{
  labelSuffix: import 'label_suffix.libsonnet',
  tenantAttribute: import 'tenant_attribute.libsonnet',
}
