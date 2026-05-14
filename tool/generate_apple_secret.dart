// Dart script to generate an Apple client secret JWT for Supabase OAuth.
// Usage: dart run tool/generate_apple_secret.dart <path-to-p8> <team-id> <key-id> <services-id>
// Example: dart run tool/generate_apple_secret.dart AuthKey_XXXXXX.p8 W7KP8TUL56 M9T63L33Q2 com.hextrail.app.signin

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:jwt_encode/jwt_encode.dart';

void main(List<String> args) async {
  if (args.length != 4) {
    print('Usage: dart run tool/generate_apple_secret.dart <p8> <team-id> <key-id> <services-id>');
    exit(1);
  }
  final p8Path = args[0];
  final teamId = args[1];
  final keyId = args[2];
  final clientId = args[3];

  final privateKey = await File(p8Path).readAsString();
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final exp = now + 86400 * 180; // 180 days
  final payload = {
    'iss': teamId,
    'iat': now,
    'exp': exp,
    'aud': 'https://appleid.apple.com',
    'sub': clientId,
  };
  final headers = {'kid': keyId, 'alg': 'ES256'};
  final jwt = JwtEncode.sign(payload, privateKey, algorithm: JwtAlgorithm.ES256, headers: headers);
  print(jwt);
}
