import 'package:drift/drift.dart';

import '../enums.dart';

class QuickActionConfigs extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get contentType => textEnum<QuickActionContentType>()();
  TextColumn get actionKey => text()();
  IntColumn get sortOrder => integer()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
        {contentType, actionKey},
      ];
}
