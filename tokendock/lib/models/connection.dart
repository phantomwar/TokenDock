class Connection {
  const Connection({
    required this.id,
    required this.provider,
    required this.displayName,
    required this.group,
    required this.plan,
    required this.credentialRef,
    required this.enabled,
    this.authType,
    this.identityKey,
    this.providerData,
  });

  final String id;
  final String provider;
  final String displayName;
  final String? group;
  final String? plan;
  final String credentialRef;
  final bool enabled;
  final String? authType;
  final String? identityKey;
  final String? providerData;
}
