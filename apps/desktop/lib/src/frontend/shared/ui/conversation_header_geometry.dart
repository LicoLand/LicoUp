abstract final class ConversationHeaderGeometry {
  static const double avatarExtent = 40;
  static const double avatarMarkExtent = 22;
  static const double capsuleInsetH = 12;
  static const double capsuleInsetV = 8;
  static const double capsulePadH = 12;
  static const double capsulePadV = 8;
  static const double capsuleButtonGap = 8;
  static const double capsuleCornerRadius = 22;
  static const double composerAssistantExtent = 32;
  static const double composerAssistantMarkExtent = 16;
  static const double rosterPadH = 4;
  static const double rosterExtent = avatarExtent + rosterPadH * 2;
  static const double rosterScrollbarThickness = 2;
  static const double rosterMemberExtent = avatarExtent;
  static const double rosterQuotaRingThickness = 2;
  static const double rosterQuotaRingInset = 1;
  static const double rosterQuotaAvatarExtent =
      rosterMemberExtent -
      (rosterQuotaRingThickness + rosterQuotaRingInset) * 2;
  static const double rosterQuotaAvatarMarkExtent = 18;
  static const double rosterMemberGap = 5;
  static const double rosterVerticalInset = 5;
}
