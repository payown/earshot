import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../data/db/app_database.dart';
import '../../data/rss/rss_parser.dart';

final appDatabaseProvider = Provider<AppDatabase>(
  (ref) {
    final db = AppDatabase();
    ref.onDispose(db.close);
    return db;
  },
);

final dioProvider = Provider<Dio>(
  (ref) => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 15),
    ),
  ),
);

/// App-wide ScaffoldMessenger key, assigned to the root MaterialApp so global
/// coordinators (e.g. the export flow) can show SnackBars without a screen
/// context, on any route.
final scaffoldMessengerKeyProvider =
    Provider<GlobalKey<ScaffoldMessengerState>>(
      (_) => GlobalKey<ScaffoldMessengerState>(),
    );

final rssParserProvider = Provider<RssParser>((_) => RssParser());

final packageInfoProvider = FutureProvider<PackageInfo>(
  (_) => PackageInfo.fromPlatform(),
);
