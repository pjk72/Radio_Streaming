import 'dart:async';
import 'dart:ui';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/radio_provider.dart';

class ConnectivityBanner extends StatefulWidget {
  const ConnectivityBanner({super.key});

  @override
  State<ConnectivityBanner> createState() => _ConnectivityBannerState();
}

class _ConnectivityBannerState extends State<ConnectivityBanner> {
  bool _isOffline = false;
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  @override
  void initState() {
    super.initState();
    _checkInitialConnectivity();
    _subscription = Connectivity().onConnectivityChanged.listen((results) {
      _updateStatus(results);
    });
  }

  Future<void> _checkInitialConnectivity() async {
    final results = await Connectivity().checkConnectivity();
    _updateStatus(results);
  }

  void _updateStatus(List<ConnectivityResult> results) {
    final isOffline = results.contains(ConnectivityResult.none);
    if (_isOffline != isOffline) {
      setState(() {
        _isOffline = isOffline;
      });
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 1. Root Positioned.fill ensures we cover the area
    // 2. IgnorePointer(ignoring: true) ensures we don't block UNLESS we explicitly re-enable it for children
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: true,
        child: Stack(
          children: [
            Positioned(
              top: MediaQuery.of(context).padding.top - 25,
              left: 100,
              child: Visibility(
                visible: _isOffline,
                child: Consumer<RadioProvider>(
                  builder: (context, provider, child) {
                    final bool isLocal =
                        provider.currentLocalPath != null ||
                        provider.currentStation?.genre == "Local Device" ||
                        provider.currentStation?.icon == "smartphone";

                    // Hide banner if playing a local song
                    if (isLocal) {
                      return const SizedBox.shrink();
                    }

                    return IgnorePointer(
                      ignoring: false, // Re-enable touch for the banner itself
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(30),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              vertical: 6,
                              horizontal: 16,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(30),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.1),
                                width: 0.5,
                              ),
                            ),
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.wifi_off_rounded,
                                  color: Colors.white70,
                                  size: 14,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  "Offline",
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w500,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
