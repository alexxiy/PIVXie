import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:socks5_proxy/socks_client.dart';

import '../utilities/logger.dart';

// WIP wrapper layer

// TODO expand this class
class Response {
  final int code;
  final List<int> bodyBytes;

  // Lower-cased response header names mapped to their (comma-joined) values.
  // Empty by default so existing callers/tests don't need to supply them.
  final Map<String, String> headers;

  String get body => utf8.decode(bodyBytes, allowMalformed: true);

  Response(this.bodyBytes, this.code, {this.headers = const {}});
}

Map<String, String> _headerMap(HttpClientResponse response) {
  final map = <String, String>{};
  response.headers.forEach((name, values) {
    map[name.toLowerCase()] = values.join(', ');
  });
  return map;
}

class HTTP {
  const HTTP();

  Future<Response> get({
    required Uri url,
    Map<String, String>? headers,
    required ({InternetAddress host, int port})? proxyInfo,
    Duration? connectionTimeout,
  }) async {
    final httpClient = HttpClient();
    if (connectionTimeout != null) {
      httpClient.connectionTimeout = connectionTimeout;
    }
    try {
      if (proxyInfo != null) {
        SocksTCPClient.assignToHttpClient(httpClient, [
          ProxySettings(proxyInfo.host, proxyInfo.port),
        ]);
      }
      final HttpClientRequest request = await httpClient.getUrl(url);

      if (headers != null) {
        headers.forEach((key, value) => request.headers.add(key, value));
      }

      final response = await request.close();

      return Response(
        await _bodyBytes(response),
        response.statusCode,
        headers: _headerMap(response),
      );
    } catch (e, s) {
      Logging.instance.w("HTTP.get() rethrew: ", error: e, stackTrace: s);
      rethrow;
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<Uint8List> _bodyBytes(HttpClientResponse response) {
    final completer = Completer<Uint8List>();
    final List<int> bytes = [];
    response.listen(
      (data) {
        bytes.addAll(data);
      },
      onDone: () => completer.complete(Uint8List.fromList(bytes)),
      onError: (Object err, StackTrace s) {
        Logging.instance.e(
          "Http wrapper layer listen",
          error: err,
          stackTrace: s,
        );
        if (!completer.isCompleted) {
          completer.completeError(err, s);
        }
      },
      cancelOnError: true,
    );
    return completer.future;
  }
}
