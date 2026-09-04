import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:youtube_explode_dart/solvers.dart';
import 'package:youtube_explode_dart/js_challenge.dart';

/// A custom HTTP client that adds our logged-in YouTube account's
/// cookies to every single request sent to YouTube. This makes our
/// server look like a real logged-in browser instead of an anonymous
/// bot, which is the fix for YouTube's "unavailable"/rate-limit
/// errors that data-center servers (like Render) run into.
class _CookieHttpClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  final String _cookieHeader;

  _CookieHttpClient(this._cookieHeader);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (_cookieHeader.isNotEmpty) {
      request.headers['cookie'] = _cookieHeader;
    }
    return _inner.send(request);
  }
}

/// Reads the cookie string from Render's Environment settings
/// (never hard-coded here, so it's never exposed in the GitHub code).
final String _ytCookies = Platform.environment['YT_COOKIES'] ?? '';

/// Set up properly inside main() below, because solving YouTube's JS
/// challenge requires an async step (starting the Deno process) —
/// so this can't be created immediately like before.
late final YoutubeExplode _yt;

/// Shared across ALL app users, because this whole server is shared —
/// once ANY user plays a song, EVERY other user benefits from this
/// cached link instead of the server asking YouTube again. This is
/// the single biggest advantage over the old phone-only approach.
final Map<String, _CachedStream> _streamCache = {};
const Duration _cacheLifetime = Duration(minutes: 40);

class _CachedStream {
  final String url;
  final DateTime fetchedAt;
  _CachedStream(this.url) : fetchedAt = DateTime.now();
  bool get isExpired => DateTime.now().difference(fetchedAt) > _cacheLifetime;
}

/// Converts a YouTube video result into the same JSON shape the
/// Flutter app already expects (matches SongModel's fields).
Map<String, dynamic> _songToJson(Video video) {
  return {
    'id': video.id.value,
    'title': _cleanTitle(video.title),
    'artist': video.author,
    'albumArtUrl': video.thumbnails.highResUrl,
    'youtubeId': video.id.value,
  };
}

/// Same title-cleaning logic that used to live in the Flutter app —
/// moved here since the server is now the one doing the searching.
String _cleanTitle(String rawTitle) {
  String title = rawTitle;
  if (title.contains('|')) {
    title = title.split('|').first;
  }
  final patterns = [
    RegExp(r'\(.*?\)'),
    RegExp(r'\[.*?\]'),
    RegExp(r'official video', caseSensitive: false),
    RegExp(r'official music video', caseSensitive: false),
    RegExp(r'lyrical video', caseSensitive: false),
    RegExp(r'lyric video', caseSensitive: false),
    RegExp(r'full video', caseSensitive: false),
    RegExp(r'full song', caseSensitive: false),
    RegExp(r'new song', caseSensitive: false),
    RegExp(r'latest punjabi songs? \d{0,4}', caseSensitive: false),
  ];
  for (final p in patterns) {
    title = title.replaceAll(p, '');
  }
  title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
  title = title.replaceAll(RegExp(r'^[\-\.\,\s]+|[\-\.\,\s]+$'), '');
  return title.isEmpty ? rawTitle.trim() : title;
}

String _trendingQueryFor(String category) {
  switch (category) {
    case 'Punjabi':
      return 'Trending Punjabi Songs 2026';
    case 'Hindi':
      return 'Trending Hindi Songs 2026';
    case 'English':
      return 'Trending English Songs 2026';
    case 'All':
    default:
      return 'Trending Punjabi Hindi English Songs 2026';
  }
}

Future<String> _fetchStreamUrl(String youtubeId) async {
  // Try several YouTube "client identities" one by one. YouTube
  // sometimes blocks/restricts one client (e.g. the default web
  // client) while others (tv, androidVr, ios, safari) still work
  // fine for the exact same video. This is the officially supported
  // way the youtube_explode_dart package handles this — see
  // getManifest(videoId, ytClients: [...]) in the package docs.
  final clientsToTry = [
    YoutubeApiClient.tv,
    YoutubeApiClient.androidVr,
    YoutubeApiClient.ios,
    YoutubeApiClient.safari,
  ];

  Object? lastError;
  for (final client in clientsToTry) {
    try {
      final manifest = await _yt.videos.streamsClient.getManifest(
        youtubeId,
        ytClients: [client],
      );
      if (manifest.muxed.isNotEmpty) {
        return manifest.muxed.withHighestBitrate().url.toString();
      }
      if (manifest.audioOnly.isNotEmpty) {
        return manifest.audioOnly.withHighestBitrate().url.toString();
      }
      // This client returned a manifest but with no usable streams —
      // try the next client instead of giving up.
      print('Client $client gave no playable streams for $youtubeId');
    } catch (e) {
      lastError = e;
      print('Client $client failed for $youtubeId: $e');
      continue;
    }
  }
  throw Exception(
      'This song has no playable stream on YouTube (tried all clients). Last error: $lastError');
}

Future<String> _getAudioStreamUrl(String youtubeId) async {
  final cached = _streamCache[youtubeId];
  if (cached != null && !cached.isExpired) {
    return cached.url;
  }

  const maxAttempts = 3;
  Object? lastError;
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      final url = await _fetchStreamUrl(youtubeId);
      _streamCache[youtubeId] = _CachedStream(url);
      return url;
    } catch (e) {
      lastError = e;
      final isRateLimit = e.toString().contains('RequestLimitExceeded');
      if (isRateLimit && attempt < maxAttempts) {
        await Future.delayed(Duration(seconds: 3 * attempt));
        continue;
      }
      break;
    }
  }
  throw Exception('Could not load this song: $lastError');
}

Response _json(Object data, {int status = 200}) {
  return Response(
    status,
    body: jsonEncode(data),
    headers: {'Content-Type': 'application/json'},
  );
}

Future<Response> _handleSearch(Request request) async {
  final query = request.url.queryParameters['q'];
  if (query == null || query.trim().isEmpty) {
    return _json({'error': 'Missing "q" query parameter'}, status: 400);
  }
  try {
    final results = await _yt.search.search(query);
    final songs = results.map(_songToJson).toList();
    return _json({'songs': songs});
  } catch (e) {
    return _json({'error': e.toString()}, status: 500);
  }
}

Future<Response> _handleTrending(Request request) async {
  final category = request.url.queryParameters['category'] ?? 'All';
  try {
    final results = await _yt.search.search(_trendingQueryFor(category));
    final songs = results.map(_songToJson).toList();
    return _json({'songs': songs});
  } catch (e) {
    return _json({'error': e.toString()}, status: 500);
  }
}

Future<Response> _handleStream(Request request, String youtubeId) async {
  try {
    final url = await _getAudioStreamUrl(youtubeId);
    return _json({'url': url});
  } catch (e) {
    return _json({'error': e.toString()}, status: 500);
  }
}

void main(List<String> args) async {
  print('Cookie length loaded: ${_ytCookies.length}');

  // Try to start the Deno JS-challenge solver. On Render, the
  // Dockerfile places the "deno" program where the system can find
  // it, so this succeeds. On a local Windows computer (without Deno
  // installed), this will fail — which is fine, we just continue
  // without it instead of crashing the whole server.
  //
  // NOTE: the correct type name from the youtube_explode_dart package
  // is "BaseJSChallengeSolver" (from js_challenge.dart), NOT
  // "JsChallengeSolver". Using the wrong name is what broke the build
  // last time.
  BaseJSChallengeSolver? jsSolver;
  try {
    jsSolver = await DenoEJSSolver.init();
    print('Deno JS solver started successfully.');
  } catch (e) {
    print(
        'Deno JS solver not available (expected on local Windows testing): $e');
  }

  _yt = YoutubeExplode(
    httpClient: YoutubeHttpClient(_CookieHttpClient(_ytCookies)),
    jsSolver: jsSolver,
  );

  final router = Router();

  router.get('/search', _handleSearch);
  router.get('/trending', _handleTrending);
  router.get('/stream/<youtubeId>', _handleStream);
  router.get(
    '/',
    (Request request) => Response.ok('SoundWave backend is running.'),
  );

  final handler =
      const Pipeline().addMiddleware(logRequests()).addHandler(router.call);

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
  print('SoundWave backend listening on port ${server.port}');
}
