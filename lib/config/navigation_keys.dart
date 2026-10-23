import 'package:flutter/material.dart';

/// Global navigator key for root-level navigation operations
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Global scaffold messenger key for root-level snackbars across screens
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
