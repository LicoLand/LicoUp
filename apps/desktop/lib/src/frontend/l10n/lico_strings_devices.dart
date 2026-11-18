import 'package:licoup/src/frontend/l10n/lico_strings_base.dart';

/// Interface strings of the Devices surface.
extension LicoStringsDevices on LicoStrings {
  String get devices => localized('devices', isChinese ? '设备' : 'Devices');
  String get devicesLegacyPairingNotice => localized(
    'devicesLegacyPairingNotice',
    isChinese
        ? 'LicoUp 0.3.0 之前配对的设备不会保留。请重新配对你的设备。'
        : 'Devices paired before LicoUp 0.3.0 are not carried over. '
              'Pair your devices again.',
  );
  String get devicesDismiss =>
      localized('devicesDismiss', isChinese ? '知道了' : 'Dismiss');
  String get devicesEnrollTitle =>
      localized('devicesEnrollTitle', isChinese ? '加入站点' : 'Join a station');
  String get devicesEnrollHint => localized(
    'devicesEnrollHint',
    isChinese
        ? '输入 LicoArc 站点地址和邀请码，让这台设备可以与其他桌面配对。'
        : 'Enter a LicoArc station address and invitation so this device can '
              'pair with other desktops.',
  );
  String get devicesStation =>
      localized('devicesStation', isChinese ? '站点地址' : 'Station address');
  String get devicesInvitation =>
      localized('devicesInvitation', isChinese ? '邀请码' : 'Invitation');
  String get devicesCaPem => localized(
    'devicesCaPem',
    isChinese ? 'CA 证书 PEM（可选）' : 'CA certificate PEM (optional)',
  );
  String get devicesEnroll =>
      localized('devicesEnroll', isChinese ? '加入' : 'Join');
  String get devicesEnrolledStation =>
      localized('devicesEnrolledStation', isChinese ? '站点' : 'Station');
  String get devicesMailbox =>
      localized('devicesMailbox', isChinese ? '信箱' : 'Mailbox');
  String get devicesPairTitle =>
      localized('devicesPairTitle', isChinese ? '配对设备' : 'Pair a device');
  String get devicesPairLabel => localized(
    'devicesPairLabel',
    isChinese ? '对方设备名称（可选）' : 'Name for the other device (optional)',
  );
  String get devicesOfferPairing => localized(
    'devicesOfferPairing',
    isChinese ? '生成配对码' : 'Create pairing code',
  );
  String get devicesOfferedCodeHint => localized(
    'devicesOfferedCodeHint',
    isChinese
        ? '在另一台设备上输入此配对码。配对码只能使用一次。'
        : 'Enter this code on the other device. It can be used once.',
  );
  String get devicesPairingCode =>
      localized('devicesPairingCode', isChinese ? '配对码' : 'Pairing code');
  String get devicesCopyPairingCode =>
      localized('devicesCopyPairingCode', isChinese ? '复制配对码' : 'Copy code');
  String get devicesPairingCodeCopied => localized(
    'devicesPairingCodeCopied',
    isChinese ? '配对码已复制' : 'Pairing code copied',
  );
  String get devicesClaimCode => localized(
    'devicesClaimCode',
    isChinese ? '输入另一台设备的配对码' : "Enter the other device's code",
  );
  String get devicesClaim =>
      localized('devicesClaim', isChinese ? '配对' : 'Pair');
  String get devicesPairings =>
      localized('devicesPairings', isChinese ? '配对进度' : 'Pairing progress');
  String get devicesRoleOfferer =>
      localized('devicesRoleOfferer', isChinese ? '本机发起' : 'Offered here');
  String get devicesRoleClaimer =>
      localized('devicesRoleClaimer', isChinese ? '本机加入' : 'Claimed here');
  String get devicesStateAwaitingClaim => localized(
    'devicesStateAwaitingClaim',
    isChinese ? '等待对方输入配对码' : 'Waiting for the other device',
  );
  String get devicesStateAwaitingReply => localized(
    'devicesStateAwaitingReply',
    isChinese ? '等待对方确认' : 'Waiting for confirmation',
  );
  String get devicesStateCompleted =>
      localized('devicesStateCompleted', isChinese ? '已配对' : 'Paired');
  String get devicesStateFailed =>
      localized('devicesStateFailed', isChinese ? '配对失败' : 'Failed');
  String get devicesCancelPairing =>
      localized('devicesCancelPairing', isChinese ? '取消' : 'Cancel');
  String get devicesPeers =>
      localized('devicesPeers', isChinese ? '已配对设备' : 'Paired devices');
  String get devicesNoPeers =>
      localized('devicesNoPeers', isChinese ? '还没有配对设备' : 'No paired devices');
  String get devicesPairedAt =>
      localized('devicesPairedAt', isChinese ? '配对于' : 'Paired');
  String get devicesUnpair =>
      localized('devicesUnpair', isChinese ? '取消配对' : 'Unpair');
  String devicesUnpairConfirm(String label) => isChinese
      ? '取消与 $label 的配对？之后需要重新配对才能互发消息。'
      : 'Unpair $label? You will need to pair again to exchange messages.';
  String get devicesMessageTitle => localized(
    'devicesMessageTitle',
    isChinese ? '发送智能体消息' : 'Send an agent message',
  );
  String get devicesMessageAgent => localized(
    'devicesMessageAgent',
    isChinese ? '对方设备上的智能体' : "Agent on the other device",
  );
  String get devicesMessageBody =>
      localized('devicesMessageBody', isChinese ? '消息' : 'Message');
  String get devicesSendMessage =>
      localized('devicesSendMessage', isChinese ? '发送' : 'Send');
  String devicesOutstanding(int count) => isChinese
      ? '正在等待 $count 条结果'
      : 'Waiting for $count ${count == 1 ? 'result' : 'results'}';
  String get devicesResults =>
      localized('devicesResults', isChinese ? '结果' : 'Results');
  String get devicesNoResults => localized(
    'devicesNoResults',
    isChinese ? '这台设备还没有返回结果' : 'No results from this device yet',
  );
  String get devicesResultCompleted =>
      localized('devicesResultCompleted', isChinese ? '已完成' : 'Completed');
  String get devicesResultFailed =>
      localized('devicesResultFailed', isChinese ? '失败' : 'Failed');
  String get devicesEnrolled =>
      localized('devicesEnrolled', isChinese ? '已加入站点' : 'Joined the station');
  String get devicesPairingClaimed => localized(
    'devicesPairingClaimed',
    isChinese ? '已提交配对码' : 'Pairing code submitted',
  );
  String get devicesPairingCancelled => localized(
    'devicesPairingCancelled',
    isChinese ? '配对已取消' : 'Pairing cancelled',
  );
  String get devicesUnpaired =>
      localized('devicesUnpaired', isChinese ? '已取消配对' : 'Device unpaired');
  String get devicesMessageSent =>
      localized('devicesMessageSent', isChinese ? '消息已发送' : 'Message sent');

  /// The visible message of one Devices failure code; an unknown code shows
  /// the code itself.
  String devicesFailure(String code) => switch (code) {
    'devices_station_invalid' =>
      isChinese
          ? '站点地址必须是 https 地址。'
          : 'The station address must be an https URL.',
    'devices_invitation_required' =>
      isChinese ? '请输入邀请码。' : 'Enter the invitation.',
    'devices_pairing_code_required' =>
      isChinese ? '请输入配对码。' : 'Enter the pairing code.',
    'devices_peer_required' =>
      isChinese ? '请选择已配对设备。' : 'Choose a paired device.',
    'devices_message_agent_required' =>
      isChinese ? '请输入智能体。' : 'Enter the agent.',
    'devices_message_body_required' =>
      isChinese ? '请输入消息。' : 'Enter a message.',
    'devices_pairing_code_copy_failed' =>
      isChinese ? '无法复制配对码。' : 'The pairing code could not be copied.',
    _ => code,
  };
}
