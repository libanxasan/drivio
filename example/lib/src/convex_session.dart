import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Anonymous sign-in on DriVio's Convex deployment (Convex Auth), over Convex's
/// HTTP API so it also works in the background upload isolate.
///
/// The refresh token is kept in a file in the app's support directory; access
/// tokens are short lived and kept in memory. No personal data is involved.
class ConvexSession {
  /// Creates a session for the deployment at [convexUrl].
  ConvexSession(
    this.convexUrl, {
    http.Client? client,
    Future<File> Function()? file,
  })  : _client = client ?? http.Client(),
        _file = file ?? _defaultFile;

  /// The deployment URL (`https://<deployment>.convex.cloud`).
  final String convexUrl;
  final http.Client _client;
  final Future<File> Function() _file;

  String? _userId;
  String? _refreshToken;
  String? _token;
  DateTime _tokenExpiresAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<String?>? _refreshing;

  static Future<File> _defaultFile() async => File(
      '${(await getApplicationSupportDirectory()).path}/drivio_convex_session.json');

  /// The anonymous user id, once signed in. It owns recordings and the stream.
  String? get userId => _userId;

  /// Restores a stored session.
  Future<void> restore() async {
    final file = await _file();
    if (!await file.exists()) return;
    try {
      final stored =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      _userId = stored['userId'] as String?;
      _refreshToken = stored['refreshToken'] as String?;
    } on FormatException {
      await file.delete();
    }
  }

  /// Restores the session, or signs in anonymously when there is none.
  Future<String> ensureSignedIn() async {
    await restore();
    if (_userId != null && _refreshToken != null) return _userId!;
    final value = await _action('auth:signIn', {'provider': 'anonymous'});
    await _accept((value as Map)['tokens'] as Map?);
    return _userId!;
  }

  /// A valid access token, refreshing the session when needed.
  Future<String?> token() async {
    if (_token != null &&
        DateTime.now()
            .isBefore(_tokenExpiresAt.subtract(const Duration(seconds: 30)))) {
      return _token;
    }
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<String?> _refresh() async {
    final refreshToken = _refreshToken;
    if (refreshToken == null) return null;
    final value = await _action('auth:signIn', {'refreshToken': refreshToken});
    final tokens = (value as Map?)?['tokens'] as Map?;
    if (tokens == null) {
      // The session ended; sign in again as a new anonymous user next time.
      _userId = null;
      _refreshToken = null;
      _token = null;
      final file = await _file();
      if (await file.exists()) await file.delete();
      return null;
    }
    await _accept(tokens);
    return _token;
  }

  Future<void> _accept(Map? tokens) async {
    final token = tokens?['token'];
    final refreshToken = tokens?['refreshToken'];
    if (token is! String || refreshToken is! String) {
      throw const FormatException('Sign-in did not return a session');
    }
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1]))),
    ) as Map<String, dynamic>;
    _userId = (payload['sub'] as String).split('|').first;
    _refreshToken = refreshToken;
    _token = token;
    _tokenExpiresAt = DateTime.fromMillisecondsSinceEpoch(
        (payload['exp'] as num).toInt() * 1000);
    final file = await _file();
    await file.writeAsString(
        jsonEncode({'userId': _userId, 'refreshToken': refreshToken}));
  }

  /// Calls a Convex mutation as the signed-in user.
  Future<Object?> mutation(String path, Map<String, Object?> args) async {
    final token = await this.token();
    if (token == null) throw StateError('Not signed in');
    return _call('mutation', path, args, token: token);
  }

  Future<Object?> _action(String path, Map<String, Object?> args) =>
      _call('action', path, args);

  Future<Object?> _call(
    String kind,
    String path,
    Map<String, Object?> args, {
    String? token,
  }) async {
    final response = await _client
        .post(
          Uri.parse('$convexUrl/api/$kind'),
          headers: {
            'Content-Type': 'application/json',
            if (token != null) 'Authorization': 'Bearer $token',
          },
          body: jsonEncode({'path': path, 'args': args, 'format': 'json'}),
        )
        .timeout(const Duration(seconds: 20));
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (body['status'] == 'success') return body['value'];
    throw ConvexCallException(
        path, response.statusCode, '${body['errorMessage']}');
  }
}

/// A Convex function call failed.
class ConvexCallException implements Exception {
  /// Creates the exception.
  const ConvexCallException(this.path, this.status, this.message);

  /// The function path.
  final String path;

  /// The HTTP status.
  final int status;

  /// Convex's error message.
  final String message;

  @override
  String toString() => 'ConvexCallException($path, $status): $message';
}
