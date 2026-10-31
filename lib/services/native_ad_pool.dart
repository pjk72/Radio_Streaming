import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Small pool of pre-loaded native ads.
///
/// A native request needs an auction plus a network round-trip, so creating it
/// only when the slot becomes visible always leaves a hole in the list. This
/// pool keeps a couple of ads ready: widgets ask for one and the pool refills
/// itself in the background.
///
/// Only one request is allowed in flight at a time. Firing several parallel
/// requests is what triggers AdMob's "Too many recently failed requests"
/// throttling when the ad unit has low fill.
///
/// Ownership: ads handed to callers belong to them and must be disposed. Ads
/// still in the pool are disposed here when they expire or when the pool is
/// full.
class NativeAdPool {
  NativeAdPool._internal();

  static final NativeAdPool instance = NativeAdPool._internal();

  static const String factoryId = 'smallAdFactory';

  static const int _targetReady = 2;
  static const int _maxReady = 3;

  /// AdMob recommends refreshing native ads at most once per hour: older ads
  /// are thrown away instead of being shown stale.
  static const Duration _maxAge = Duration(minutes: 45);

  final List<_PooledAd> _ready = [];
  final List<Completer<NativeAd?>> _waiters = [];
  NativeAd? _inFlight;
  Timer? _retryTimer;
  DateTime? _retryNotBefore;
  int _failureStreak = 0;
  int _target = _targetReady;

  bool get isSupported => !kIsWeb;

  String get adUnitId => kReleaseMode
      ? 'ca-app-pub-3351319116434923/8986498334'
      : (Platform.isAndroid
            ? 'ca-app-pub-3940256099942544/2247696110'
            : 'ca-app-pub-3940256099942544/3986624511');

  /// Ensures at least [target] ads are ready (or being loaded).
  /// Cheap to call from `build`: it only starts a request when needed.
  void preload({int target = _targetReady}) {
    if (!isSupported) return;

    _target = target.clamp(1, _maxReady).toInt();
    _dropExpired();

    final notBefore = _retryNotBefore;
    if (notBefore != null) {
      final wait = notBefore.difference(DateTime.now());
      if (wait > Duration.zero) {
        _ensureRetryTimer(wait);
        return;
      }
    }

    if (_inFlight != null) return;
    if (_ready.length >= _target) return;

    _loadOne();
  }

  /// Returns a ready ad or waits for the current request, at most [timeout].
  /// Returns `null` when the ad could not be loaded in time.
  Future<NativeAd?> acquire({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (!isSupported) return null;

    _dropExpired();
    if (_ready.isNotEmpty) {
      final ad = _ready.removeAt(0).ad;
      preload();
      return ad;
    }

    final completer = Completer<NativeAd?>();
    _waiters.add(completer);
    preload();

    final timer = Timer(timeout, () {
      if (completer.isCompleted) return;
      _waiters.remove(completer);
      completer.complete(null);
    });

    try {
      return await completer.future;
    } finally {
      timer.cancel();
    }
  }

  /// Gives an unwanted (but loaded) ad back to the pool.
  void recycle(NativeAd ad) {
    if (!isSupported) {
      ad.dispose();
      return;
    }

    _dropExpired();
    if (_ready.length >= _maxReady) {
      ad.dispose();
      return;
    }
    _ready.add(_PooledAd(ad, DateTime.now()));
    preload();
  }

  void _loadOne() {
    final ad = NativeAd(
      adUnitId: adUnitId,
      factoryId: factoryId,
      listener: NativeAdListener(
        onAdLoaded: (ad) => _onAdLoaded(ad as NativeAd),
        onAdFailedToLoad: (ad, error) => _onAdFailed(ad as NativeAd, error),
      ),
      request: const AdRequest(),
    );
    _inFlight = ad;
    ad.load();
  }

  void _onAdLoaded(NativeAd ad) {
    if (!identical(_inFlight, ad)) {
      // A stale callback from an ad we no longer track.
      ad.dispose();
      return;
    }
    _inFlight = null;

    _failureStreak = 0;
    _retryNotBefore = null;
    _retryTimer?.cancel();
    _retryTimer = null;

    // A visible slot is waiting: hand the ad over immediately.
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeAt(0);
      if (waiter.isCompleted) continue;
      waiter.complete(ad);
      preload();
      return;
    }

    _dropExpired();
    if (_ready.length >= _maxReady) {
      ad.dispose();
      return;
    }
    _ready.add(_PooledAd(ad, DateTime.now()));
    preload();
  }

  void _onAdFailed(NativeAd ad, LoadAdError error) {
    if (identical(_inFlight, ad)) {
      _inFlight = null;
    }
    ad.dispose();

    for (final waiter in _waiters) {
      if (!waiter.isCompleted) waiter.complete(null);
    }
    _waiters.clear();

    _failureStreak++;
    final message = error.message.toLowerCase();
    final isThrottled = message.contains('too many');
    final isNoFill = error.code == 3;
    final baseSeconds = isThrottled ? 300 : (isNoFill ? 60 : 10);
    final exponent = (_failureStreak - 1).clamp(0, 3).toInt();
    final delay = Duration(
      seconds: (baseSeconds * (1 << exponent)).clamp(baseSeconds, 600),
    );

    _retryNotBefore = DateTime.now().add(delay);
    _ensureRetryTimer(delay);

    debugPrint(
      'NativeAdPool: load failed (code ${error.code}): ${error.message}',
    );
  }

  void _ensureRetryTimer(Duration delay) {
    if (_retryTimer?.isActive ?? false) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      preload();
    });
  }

  void _dropExpired() {
    if (_ready.isEmpty) return;

    final cutoff = DateTime.now().subtract(_maxAge);
    _ready.removeWhere((pooled) {
      if (pooled.loadedAt.isAfter(cutoff)) return false;
      pooled.ad.dispose();
      return true;
    });
  }
}

class _PooledAd {
  _PooledAd(this.ad, this.loadedAt);

  final NativeAd ad;
  final DateTime loadedAt;
}
