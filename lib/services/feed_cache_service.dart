import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void unawaited(Future<void> future) {}

// ---------------------------------------------------------------------------
// Dedicated cache managers
// ---------------------------------------------------------------------------

class _ImageCacheManager extends CacheManager with ImageCacheManager {
  static const key = 'feed_image_cache';
  static _ImageCacheManager? _instance;
  static _ImageCacheManager get instance =>
      _instance ??= _ImageCacheManager._();
  _ImageCacheManager._()
      : super(Config(key,
            stalePeriod: const Duration(days: 7), maxNrOfCacheObjects: 300));
}

class _VideoCacheManager extends CacheManager {
  static const key = 'feed_video_cache';
  static _VideoCacheManager? _instance;
  static _VideoCacheManager get instance =>
      _instance ??= _VideoCacheManager._();
  _VideoCacheManager._()
      : super(Config(key,
            stalePeriod: const Duration(days: 3),
            maxNrOfCacheObjects: 30,
            fileService: HttpFileService()));
}

// ---------------------------------------------------------------------------
// FeedCacheService
// ---------------------------------------------------------------------------

class FeedCacheService {
  // ── Keys ──────────────────────────────────────────────────────────────────
  static const _cachedForYouPostsKey = 'cached_for_you_posts_v29';
  static const _immediatePostsCacheKey = 'immediate_posts_cache_v1';
  static const _seenPostsKey = 'seen_posts';
  static const _mediaPreloadedKey = 'media_preloaded_v2';
  static const _cacheUsedInSessionKey = 'cache_used_in_session';
  static const _currentSessionHiddenKey = 'current_session_hidden';
  static const _lastCacheUpdateAttemptKey = 'last_cache_update_attempt';
  static const _lastUserIdKey = 'feed_last_user_id';

  static const _cacheValidityDuration = Duration(hours: 24);

  // ── Session tracking ──────────────────────────────────────────────────────
  static String? _cachedSessionId;
  static String get _currentSessionId {
    _cachedSessionId ??=
        '${DateTime.now().millisecondsSinceEpoch}_${UniqueKey().hashCode}';
    return _cachedSessionId!;
  }

  static void resetSession() => _cachedSessionId = null;

  // ── In-memory userId cache ─────────────────────────────────────────────────
  static String? _cachedLastUserId;

  static Future<void> warmUserIdCache() async {
    final prefs = await SharedPreferences.getInstance();
    _cachedLastUserId = prefs.getString(_lastUserIdKey);
  }

  static String? getLastUserIdSync() => _cachedLastUserId;

  static Future<void> persistLastUserId(String userId) async {
    if (userId.isEmpty || userId == _cachedLastUserId) return;
    _cachedLastUserId = userId;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastUserIdKey, userId);
    } catch (_) {}
  }

  // ── Concurrency guard ─────────────────────────────────────────────────────
  static bool _isLoadingCache = false;
  static Completer<List<Map<String, dynamic>>?>? _cacheLoadCompleter;

  // =========================================================================
  // 1. IMMEDIATE CACHE  (fast cold-start path)
  // =========================================================================

  static Future<void> cacheCurrentPostsNow(
    List<Map<String, dynamic>> posts,
    String userId,
  ) async {
    if (posts.isEmpty || userId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final toCache = posts.take(3).toList();
      await prefs.setString(
        _immediatePostsCacheKey,
        jsonEncode({
          'posts': toCache,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'userId': userId,
          'sessionId': _currentSessionId,
        }),
      );
      unawaited(_downloadAndCacheMedia(toCache));
    } catch (e) {
      // ignore
    }
  }

  static Future<List<Map<String, dynamic>>?> loadImmediatelyCachedPosts(
    String userId, {
    bool skipUserIdCheck = false,
  }) async {
    if (userId.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_immediatePostsCacheKey);
      if (raw == null) {
        return null;
      }

      final data = jsonDecode(raw) as Map<String, dynamic>;
      final cachedUserId = data['userId'] as String? ?? '';
      final timestamp = data['timestamp'] as int? ?? 0;
      final sessionId = data['sessionId'] as String?;
      final age = DateTime.now().millisecondsSinceEpoch - timestamp;

      if (!skipUserIdCheck && cachedUserId != userId) {
        return null;
      }
      if (age > _cacheValidityDuration.inMilliseconds) {
        return null;
      }
      if (sessionId == _currentSessionId) {
        return null;
      }

      final posts = (data['posts'] as List<dynamic>?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          [];
      if (posts.isEmpty) return null;

      return posts;
    } catch (e) {
      return null;
    }
  }

  // =========================================================================
  // 2. VIDEO / IMAGE DISK CACHE
  // =========================================================================

  static Future<File?> getCachedVideoFile(String videoUrl) async {
    if (videoUrl.isEmpty) return null;
    try {
      final info = await _VideoCacheManager.instance.getFileFromCache(videoUrl);
      if (info != null && info.file.existsSync()) {
        return info.file;
      }
    } catch (_) {}
    return null;
  }

  static Future<File?> cacheVideoFile(String videoUrl) async {
    if (videoUrl.isEmpty) return null;
    try {
      final cached = await getCachedVideoFile(videoUrl);
      if (cached != null) return cached;
      final file = await _VideoCacheManager.instance.getSingleFile(videoUrl);
      return file.existsSync() ? file : null;
    } catch (_) {
      return null;
    }
  }

  static Future<File?> getCachedImageFile(String imageUrl) async {
    if (imageUrl.isEmpty) return null;
    try {
      final info = await _ImageCacheManager.instance.getFileFromCache(imageUrl);
      if (info != null && info.file.existsSync()) {
        return info.file;
      }
    } catch (_) {}
    return null;
  }

  static Future<File?> cacheImageFile(String imageUrl) async {
    if (imageUrl.isEmpty) return null;
    try {
      final cached = await getCachedImageFile(imageUrl);
      if (cached != null) return cached;
      final file = await _ImageCacheManager.instance.getSingleFile(imageUrl);
      return file.existsSync() ? file : null;
    } catch (_) {
      return null;
    }
  }

  // =========================================================================
  // 3. LEGACY ROLLING CACHE
  // =========================================================================

  static Future<void> cacheForYouPosts(
    List<Map<String, dynamic>> posts,
    String userId, {
    List<Map<String, dynamic>>? nextBatchPosts,
    bool forceUpdate = false,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!forceUpdate) {
        final last = prefs.getInt(_lastCacheUpdateAttemptKey) ?? 0;
        // FIXED: added missing '<' operator
        if (DateTime.now().millisecondsSinceEpoch - last <
            const Duration(minutes: 1).inMilliseconds) return;
      }

      final seenPosts = await getSeenPosts(userId);
      final currentIds = posts
          .map((p) => p['postId']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      final effectivelySeen = {...seenPosts, ...currentIds};
      final allAvailable = nextBatchPosts ?? [];
      final unseen = allAvailable.where((p) {
        final id = p['postId']?.toString() ?? '';
        return id.isNotEmpty && !effectivelySeen.contains(id);
      }).toList();

      if (unseen.isEmpty) {
        final existing = prefs.getString(_cachedForYouPostsKey);
        if (existing != null) {
          try {
            final d = jsonDecode(existing) as Map<String, dynamic>;
            final age =
                DateTime.now().millisecondsSinceEpoch - (d['timestamp'] as int);
            if (d['userId'] == userId &&
                age < _cacheValidityDuration.inMilliseconds) return;
            if (d['userId'] != userId) await _clearCache(userId);
          } catch (_) {}
        }
        return;
      }

      final toCache = unseen.take(2).toList();
      await _markPostsAsHiddenInCurrentSession(toCache, userId);
      await prefs.setString(
        _cachedForYouPostsKey,
        jsonEncode({
          'posts': toCache,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'userId': userId,
          'sessionId': _currentSessionId,
        }),
      );
      await prefs.setBool(_cacheUsedInSessionKey, false);
      await prefs.setInt(
          _lastCacheUpdateAttemptKey, DateTime.now().millisecondsSinceEpoch);
      unawaited(_downloadAndCacheMedia(toCache));
    } catch (_) {}
  }

  static Future<List<Map<String, dynamic>>?> loadCachedForYouPosts(
      String userId) async {
    if (_isLoadingCache && _cacheLoadCompleter != null) {
      return _cacheLoadCompleter!.future;
    }
    _isLoadingCache = true;
    _cacheLoadCompleter = Completer<List<Map<String, dynamic>>?>();

    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_cacheUsedInSessionKey) ?? false) {
        _cacheLoadCompleter!.complete(null);
        return null;
      }
      final raw = prefs.getString(_cachedForYouPostsKey);
      if (raw != null) {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        final cachedUserId = data['userId'] as String;
        final sessionId = data['sessionId'] as String?;
        final age =
            DateTime.now().millisecondsSinceEpoch - (data['timestamp'] as int);
        final valid = cachedUserId == userId &&
            age < _cacheValidityDuration.inMilliseconds;

        if (sessionId == _currentSessionId) {
          _cacheLoadCompleter!.complete(null);
          return null;
        }
        if (valid) {
          final posts = (data['posts'] as List)
              .map<Map<String, dynamic>>((p) => Map<String, dynamic>.from(p))
              .toList();
          if (posts.isNotEmpty) {
            await prefs.setBool(_cacheUsedInSessionKey, true);
            _cacheLoadCompleter!.complete(posts);
            return posts;
          }
        } else {
          await _clearCache(userId);
        }
      }
    } catch (_) {
    } finally {
      _isLoadingCache = false;
      if (!_cacheLoadCompleter!.isCompleted) {
        _cacheLoadCompleter!.complete(null);
      }
      _cacheLoadCompleter = null;
    }
    return null;
  }

  static Future<void> updateCacheAfterScroll(
    String userId,
    List<Map<String, dynamic>> currentBatch,
    List<Map<String, dynamic>>? nextBatch,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final seenPosts = await getSeenPosts(userId);
      final currentIds = currentBatch
          .map((p) => p['postId']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      final effectivelySeen = {...seenPosts, ...currentIds};
      final raw = prefs.getString(_cachedForYouPostsKey);
      if (raw == null) {
        await cacheForYouPosts(currentBatch, userId, nextBatchPosts: nextBatch);
        return;
      }
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['userId'] != userId) {
        await _clearCache(userId);
        await cacheForYouPosts(currentBatch, userId, nextBatchPosts: nextBatch);
        return;
      }
      final cachedPosts = (data['posts'] as List)
          .map<Map<String, dynamic>>((p) => Map<String, dynamic>.from(p))
          .toList();
      final hasSeen = cachedPosts.any(
          (cp) => effectivelySeen.contains(cp['postId']?.toString() ?? ''));
      if (hasSeen && nextBatch != null && nextBatch.isNotEmpty) {
        await cacheForYouPosts(currentBatch, userId, nextBatchPosts: nextBatch);
      }
    } catch (_) {}
  }

  static Future<void> safeCacheUpdate(
    String userId,
    List<Map<String, dynamic>> currentBatch,
    List<Map<String, dynamic>> nextBatch,
  ) async {
    if (nextBatch.isEmpty) return;
    await Future.delayed(const Duration(milliseconds: 500));
    final seenPosts = await getSeenPosts(userId);
    final currentIds = currentBatch
        .map((p) => p['postId']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    final effectivelySeen = {...seenPosts, ...currentIds};
    final unseen = nextBatch.where((p) {
      final id = p['postId']?.toString() ?? '';
      return id.isNotEmpty && !effectivelySeen.contains(id);
    }).toList();
    if (unseen.isNotEmpty) {
      await cacheForYouPosts(currentBatch, userId,
          nextBatchPosts: nextBatch, forceUpdate: true);
    }
  }

  // =========================================================================
  // SEEN-POSTS TRACKING
  // =========================================================================

  static Future<Set<String>> getSeenPosts(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return Set<String>.from(
          prefs.getStringList('${_seenPostsKey}_$userId') ?? []);
    } catch (_) {
      return {};
    }
  }

  static Future<void> markPostAsSeen(String postId, String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final seen = await getSeenPosts(userId);
      seen.add(postId);
      final trimmed = seen.toList();
      if (trimmed.length > 1000) {
        trimmed.removeRange(0, trimmed.length - 1000);
      }
      await prefs.setStringList('${_seenPostsKey}_$userId', trimmed);
    } catch (_) {}
  }

  static Future<void> clearSeenPosts(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('${_seenPostsKey}_$userId');
    } catch (_) {}
  }

  // =========================================================================
  // SESSION-HIDDEN TRACKING
  // =========================================================================

  static Future<void> _markPostsAsHiddenInCurrentSession(
      List<Map<String, dynamic>> posts, String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hidden = await _getCurrentSessionHiddenPosts(userId);
      for (final p in posts) {
        final id = p['postId']?.toString();
        if (id != null && id.isNotEmpty) hidden.add(id);
      }
      await prefs.setStringList(
          '$_currentSessionHiddenKey$userId', hidden.toList());
    } catch (_) {}
  }

  static Future<Set<String>> _getCurrentSessionHiddenPosts(
      String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return Set<String>.from(
          prefs.getStringList('$_currentSessionHiddenKey$userId') ?? []);
    } catch (_) {
      return {};
    }
  }

  static Future<void> clearCurrentSessionHiddenPosts(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_currentSessionHiddenKey$userId');
    } catch (_) {}
  }

  static Future<List<Map<String, dynamic>>> filterOutCurrentSessionHiddenPosts(
      List<Map<String, dynamic>> posts, String userId) async {
    try {
      final hidden = await _getCurrentSessionHiddenPosts(userId);
      return posts
          .where((p) =>
              (p['postId']?.toString() ?? '').isNotEmpty &&
              !hidden.contains(p['postId']?.toString()))
          .toList();
    } catch (_) {
      return posts;
    }
  }

  // =========================================================================
  // CACHE CLEARING
  // =========================================================================

  static Future<void> clearCache(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _cachedLastUserId = null;
      await Future.wait([
        prefs.remove(_cachedForYouPostsKey),
        prefs.remove(_immediatePostsCacheKey),
        prefs.remove(_mediaPreloadedKey),
        prefs.remove(_cacheUsedInSessionKey),
        prefs.remove(_lastCacheUpdateAttemptKey),
        prefs.remove('$_currentSessionHiddenKey$userId'),
        _ImageCacheManager.instance.emptyCache(),
        _VideoCacheManager.instance.emptyCache(),
      ]);
    } catch (_) {}
  }

  static Future<void> _clearCache(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        prefs.remove(_cachedForYouPostsKey),
        prefs.remove(_immediatePostsCacheKey),
        prefs.remove(_mediaPreloadedKey),
        prefs.remove(_cacheUsedInSessionKey),
        prefs.remove(_lastCacheUpdateAttemptKey),
        prefs.remove('$_currentSessionHiddenKey$userId'),
      ]);
    } catch (_) {}
  }

  static Future<void> resetSessionFlag(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_cacheUsedInSessionKey, false);
    await clearCurrentSessionHiddenPosts(userId);
  }

  static Future<bool> isMediaPreloaded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_mediaPreloadedKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> clearCurrentSessionSeenPosts(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('${_seenPostsKey}_${_currentSessionId}_$userId');
    } catch (_) {}
  }

  // =========================================================================
  // PRIVATE HELPERS
  // =========================================================================

  static Future<void> _downloadAndCacheMedia(
      List<Map<String, dynamic>> posts) async {
    for (final post in posts) {
      final postUrl = post['postUrl']?.toString() ?? '';
      final profImage = post['profImage']?.toString() ?? '';
      if (postUrl.isNotEmpty) {
        if (_isVideoUrl(postUrl)) {
          unawaited(_safeDownloadVideo(postUrl));
        } else if (_isImageUrl(postUrl)) {
          unawaited(_safeDownloadImage(postUrl));
        }
      }
      if (profImage.isNotEmpty &&
          profImage != 'default' &&
          _isImageUrl(profImage)) {
        unawaited(_safeDownloadImage(profImage));
      }
    }
  }

  static Future<void> _safeDownloadImage(String url) async {
    try {
      await _ImageCacheManager.instance.getSingleFile(url);
    } catch (_) {}
  }

  static Future<void> _safeDownloadVideo(String url) async {
    try {
      await _VideoCacheManager.instance.getSingleFile(url);
    } catch (_) {}
  }

  static bool _isVideoUrl(String url) {
    final l = url.toLowerCase();
    return l.endsWith('.mp4') ||
        l.endsWith('.mov') ||
        l.endsWith('.avi') ||
        l.endsWith('.mkv') ||
        l.endsWith('.webm') ||
        l.endsWith('.m4v') ||
        l.endsWith('.3gp') ||
        l.contains('/video/') ||
        l.contains('video=true');
  }

  static bool _isImageUrl(String url) {
    final l = url.toLowerCase();
    return l.endsWith('.jpg') ||
        l.endsWith('.jpeg') ||
        l.endsWith('.png') ||
        l.endsWith('.gif') ||
        l.endsWith('.webp') ||
        l.endsWith('.bmp') ||
        l.contains('/image/') ||
        l.contains('/images/') ||
        l.contains('type=image') ||
        l.contains('image=true') ||
        l.contains('firebasestorage.googleapis.com') ||
        l.contains('supabase.co/storage');
  }
}
