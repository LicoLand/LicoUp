class MobileRelayCommand {
  const MobileRelayCommand({
    required this.commandId,
    required this.type,
    required this.payload,
    required this.status,
    required this.createdAt,
  });

  final String commandId;
  final String type;
  final Map<String, dynamic> payload;
  final String status;
  final String createdAt;

  factory MobileRelayCommand.fromJson(Map<String, dynamic> json) {
    return MobileRelayCommand(
      commandId: (json['commandId'] ?? '').toString(),
      type: (json['type'] ?? '').toString(),
      payload: json['payload'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(json['payload'] as Map)
          : const {},
      status: (json['status'] ?? '').toString(),
      createdAt: (json['createdAt'] ?? '').toString(),
    );
  }
}
