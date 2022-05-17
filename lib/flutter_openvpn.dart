import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:streaming_shared_preferences/streaming_shared_preferences.dart';

typedef OnConnectionStatusChanged = Function(
    String duration, String lastPacketReceive, String byteIn, String byteOut);

/// Track vpn profile status.
typedef OnProfileStatusChanged = Function(bool isProfileLoaded);

/// Track Vpn status.
///
/// Status strings are but not limited to:
/// "CONNECTING", "CONNECTED", "DISCONNECTING", "DISCONNECTED", "TIMEOUT", "EXPIRED", "INVALID", "REASSERTING", "AUTH", ...
/// print status to get full insight.
/// status might change depending on platform.
typedef OnVPNStatusChanged = Function(String status);

const String _profile = "profile";
const String _connectionUpdate = 'connectionUpdate';
const String _vpnStatus = 'vpnStatus';
const String _vpnStatusGroup = "vpnStatusGroup";
const String _connectionId = "connectionId";

class InitializationResult {
  final String? vpnCurrentStatus;
  final DateTime? latestExpireAt;
  final String? latestConnectionName;
  final String? latestConnectionId;
  InitializationResult({
    this.latestConnectionId,
    this.latestConnectionName,
    this.latestExpireAt,
    this.vpnCurrentStatus,
  });
}

class FlutterOpenvpn {
  static const MethodChannel _channel = const MethodChannel('flutter_openvpn');
  static OnProfileStatusChanged? _onProfileStatusChanged;
  static OnVPNStatusChanged? _onVPNStatusChanged;
  static OnConnectionStatusChanged? _onConnectionStatusChanged;
  static String _vpnState = "";

  /// Initialize plugin.
  ///
  /// Must be called before any use.
  ///
  /// localizedDescription and providerBundleIdentifier is only required on iOS.
  ///
  /// localizedDescription : Name of vpn profile in settings.
  ///
  /// providerBundleIdentifier : Bundle id of your vpn extension.
  ///
  ///  returns null if failed
  static Future<InitializationResult?> init(
      {String? providerBundleIdentifier,
      String? localizedDescription,
      String? groupIdentifier}) async {
    if (Platform.isIOS)
      assert(
        groupIdentifier != null &&
            providerBundleIdentifier != null &&
            localizedDescription != null,
        "These values are required for ios.",
      );
    dynamic? initializeResult = await _channel.invokeMethod("init", {
      'localizedDescription': localizedDescription,
      'providerBundleIdentifier': providerBundleIdentifier,
    }).catchError((error) => error);
    if (initializeResult is! PlatformException || initializeResult == null) {
      StreamingSharedPreferences sp = StreamingSharedPreferences();
      sp.setNativePreferencesName("flutter_openvpn");
      sp.addObserver(_connectionUpdate, (value) {
        if (value == null) return;
        List<String> values = value.split('_');
        _onConnectionStatusChanged?.call(
            values[0], values[1], values[2], values[3]);
      });
      sp.addObserver(_profile, (value) {
        _onProfileStatusChanged?.call(value == '0' ? false : true);
      });
      sp.addObserver(_vpnStatus, (value) {
        if (value == null) return;
        _vpnState = value;
        _onVPNStatusChanged?.call(value);
      });
      sp.run();

      if (Platform.isIOS) {
        StreamingSharedPreferences spGroup = StreamingSharedPreferences();
        spGroup.setNativePreferencesName(groupIdentifier!);
        spGroup.addObserver(_connectionUpdate, (value) {
          if (value == null) return;
          List<String> values = value.split('_');
          _onConnectionStatusChanged?.call(
              values[0], values[1], values[2], values[3]);
        });
        spGroup.addObserver(_vpnStatusGroup, (value) {
          if (value == null) return;
          _vpnState = value;
          _onVPNStatusChanged?.call(value);
        });
        spGroup.run();
      }

      SharedPreferences spId = await SharedPreferences.getInstance();
      if (spId.containsKey(_connectionId)) {
        List<String> spliced = spId.getString(_connectionId)!.split('{||}');
        initializeResult?.putIfAbsent('connectionId', () => spliced[1]);
        initializeResult?.putIfAbsent('connectionName', () => spliced[0]);
      }
      return InitializationResult(
        latestConnectionId:
            initializeResult == null ? null : initializeResult['connectionId'],
        latestConnectionName: initializeResult == null
            ? null
            : initializeResult['connectionName'],
        latestExpireAt: DateTime.tryParse(initializeResult == null
            ? ""
            : (initializeResult['expireAt'] ?? "")),
        vpnCurrentStatus:
            initializeResult == null ? null : initializeResult['currentStatus'],
      );
    } else {
      print('OpenVPN Initialization failed');
      print(initializeResult.message);
      print(initializeResult.details);
      return null;
    }
  }

  static Future<String?> _currentCon() async =>
      (await SharedPreferences.getInstance()).getString(_connectionId);
  static Future<String?> getVpnStatus() async {
    try {
      return await _channel.invokeMethod<String>("getStatus");
    } catch (err) {
      return null;
    }
  }

  static Future<String?> get currentProfileId async {
    List<String>? vars = (await _currentCon())?.split('{||}');
    if (vars == null) return null;
    return vars.last;
  }

  static Future<String?> get currentProfileName async {
    List<String>? vars = (await _currentCon())?.split('{||}');
    if (vars == null || vars.length != 2) return null;
    return vars.first;
  }

  /// Load profile and start connecting.
  ///
  /// if expireAt is provided
  /// Vpn session stops itself at given date.
  static Future<int> lunchVpn({
    required String ovpnFileContents,
    OnProfileStatusChanged? onProfileStatusChanged,
    OnVPNStatusChanged? onVPNStatusChanged,
    DateTime? expireAt,
    String user = '',
    String pass = '',
    OnConnectionStatusChanged? onConnectionStatusChanged,
    String connectionName = '',
    String connectionId = '',
    Duration timeOut = const Duration(seconds: 60),
  }) async {
    _onProfileStatusChanged = onProfileStatusChanged;
    _onVPNStatusChanged = onVPNStatusChanged;
    _onConnectionStatusChanged = onConnectionStatusChanged;
    SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setString(_connectionId, '$connectionName{||}$connectionId');

    dynamic isLunched = await _channel.invokeMethod(
      "lunch",
      {
        'ovpnFileContent': ovpnFileContents,
        'user': user,
        'pass': pass,
        'conName': connectionName,
        'conId': connectionId,
        'timeOut':
            Platform.isIOS ? timeOut.inSeconds.toString() : timeOut.inSeconds,
        'expireAt': expireAt == null
            ? null
            : DateFormat("yyyy-MM-dd HH:mm:ss").format(expireAt),
      },
    ).catchError((error) => error);
    if (isLunched == null) return 0;
    print((isLunched as PlatformException).message);
    return int.tryParse(isLunched.code) ?? -1;
  }

  /// stops any connected session.
  static Future<void> stopVPN() async {
    try {
      await _channel.invokeMethod("stop");
    } catch (err) {
      print(err);
    }
  }
}
