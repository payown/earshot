import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    ),
  ),
);

final rssParserProvider = Provider<RssParser>((_) => RssParser());
