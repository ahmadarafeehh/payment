import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;

class AdHelper {
  // ── App ID ──────────────────────────────────────────────────────────────────
  static String get appId {
    if (kIsWeb) return '';
    if (Platform.isAndroid) {
      return 'ca-app-pub-8139457472126187~2544639689';
    } else if (Platform.isIOS) {
      return 'ca-app-pub-8139457472126187~8421574907';
    } else {
      throw UnsupportedError('Unsupported platform');
    }
  }

  // ── Feed Screen Interstitial (the only active ad) ───────────────────────────
  static String get feedInterstitialAdUnitId {
    if (kIsWeb) return '';
    if (Platform.isAndroid) {
      return 'ca-app-pub-8139457472126187/8507251108';
    } else if (Platform.isIOS) {
      return 'ca-app-pub-8139457472126187/9238960415';
    } else {
      throw UnsupportedError('Unsupported platform');
    }
  }

  // ── All other ad units (disabled — kept for future use) ────────────────────
  static String get feedNativeAdUnitId {
    if (kIsWeb) return '';
    if (Platform.isAndroid) {
      return 'ca-app-pub-8139457472126187/8603894968';
    } else if (Platform.isIOS) {
      return 'ca-app-pub-8139457472126187/1739049819';
    } else {
      throw UnsupportedError('Unsupported platform');
    }
  }

  static String get feedBannerAdUnitId {
    if (kIsWeb) return '';
    if (Platform.isAndroid) {
      return 'ca-app-pub-8139457472126187/4547507566';
    } else if (Platform.isIOS) {
      return 'ca-app-pub-8139457472126187/9754837870';
    } else {
      throw UnsupportedError('Unsupported platform');
    }
  }

  static String get searchBannerAdUnitId {
    if (kIsWeb) return '';
    if (Platform.isAndroid) {
      return 'ca-app-pub-8139457472126187/4547507566';
    } else if (Platform.isIOS) {
      return 'ca-app-pub-8139457472126187/6093976226';
    } else {
      throw UnsupportedError('Unsupported platform');
    }
  }

  static String get currentProfileBannerAdUnitId {
    if (kIsWeb) return '';
    if (Platform.isAndroid) {
      return 'ca-app-pub-8139457472126187/4547507566';
    } else if (Platform.isIOS) {
      return 'ca-app-pub-8139457472126187/1392313888';
    } else {
      throw UnsupportedError('Unsupported platform');
    }
  }

  static String get otherProfileBannerAdUnitId {
    if (kIsWeb) return '';
    if (Platform.isAndroid) {
      return 'ca-app-pub-8139457472126187/4547507566';
    } else if (Platform.isIOS) {
      return 'ca-app-pub-8139457472126187/4840604309';
    } else {
      throw UnsupportedError('Unsupported platform');
    }
  }

  static String get notificationBannerAdUnitId {
    if (kIsWeb) return '';
    if (Platform.isAndroid) {
      return 'ca-app-pub-8139457472126187/4547507566';
    } else if (Platform.isIOS) {
      return 'ca-app-pub-8139457472126187/9079232213';
    } else {
      throw UnsupportedError('Unsupported platform');
    }
  }

  static String get imagescreenAdUnitId {
    if (kIsWeb) return '';
    if (Platform.isAndroid) {
      return 'ca-app-pub-8139457472126187/4547507566';
    } else if (Platform.isIOS) {
      return 'ca-app-pub-8139457472126187/1008637673';
    } else {
      throw UnsupportedError('Unsupported platform');
    }
  }

  // ── Generic fallbacks ───────────────────────────────────────────────────────
  static String get bannerAdUnitId => feedBannerAdUnitId;
  static String get interstitialAdUnitId => feedInterstitialAdUnitId;
}
