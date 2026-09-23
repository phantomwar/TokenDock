abstract interface class RefreshableCredential {
  DateTime? get expiresAt;
  Duration get refreshLead;
  Future<String> refresh(String currentSecret);
}
