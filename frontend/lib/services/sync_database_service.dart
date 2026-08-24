import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// 1. 本地阅读记录模型
class LocalReadingRecord {
  final String bookId;
  final double progress;
  final String locator;
  final int clientUpdatedAt;

  LocalReadingRecord({
    required this.bookId,
    required this.progress,
    required this.locator,
    required this.clientUpdatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'book_id': bookId,
      'progress': progress,
      'locator': locator,
      'client_updated_at': clientUpdatedAt,
    };
  }

  factory LocalReadingRecord.fromMap(Map<String, dynamic> map) {
    return LocalReadingRecord(
      bookId: map['book_id'] as String,
      progress: (map['progress'] as num).toDouble(),
      locator: map['locator'] as String,
      clientUpdatedAt: map['client_updated_at'] as int,
    );
  }
}

/// 2. 离线同步队列项模型
class SyncQueueItem {
  final int? id;
  final String bookId;
  final double progress;
  final String locator;
  final String deviceId;
  final String deviceName;
  final int clientUpdatedAt;
  final int retryCount;

  SyncQueueItem({
    this.id,
    required this.bookId,
    required this.progress,
    required this.locator,
    required this.deviceId,
    required this.deviceName,
    required this.clientUpdatedAt,
    this.retryCount = 0,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'book_id': bookId,
      'progress': progress,
      'locator': locator,
      'device_id': deviceId,
      'device_name': deviceName,
      'client_updated_at': clientUpdatedAt,
      'retry_count': retryCount,
    };
  }

  factory SyncQueueItem.fromMap(Map<String, dynamic> map) {
    return SyncQueueItem(
      id: map['id'] as int?,
      bookId: map['book_id'] as String,
      progress: (map['progress'] as num).toDouble(),
      locator: map['locator'] as String,
      deviceId: map['device_id'] as String,
      deviceName: map['device_name'] as String,
      clientUpdatedAt: map['client_updated_at'] as int,
      retryCount: map['retry_count'] as int? ?? 0,
    );
  }
}

/// 3. 本地数据库与离线同步管理器
class SyncDatabaseService {
  static SyncDatabaseService? _instance;
  static Database? _db;

  final Dio _dio;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _isFlushing = false;

  SyncDatabaseService._internal(this._dio) {
    _initConnectivityListener();
  }

  factory SyncDatabaseService(Dio dio) {
    _instance ??= SyncDatabaseService._internal(dio);
    return _instance!;
  }

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDatabase();
    return _db!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'reader_local.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        // 1. 本地阅读进度快照表 (每本书仅保留一条最新数据)
        await db.execute('''
          CREATE TABLE local_progress (
            book_id TEXT PRIMARY KEY,
            progress REAL NOT NULL,
            locator TEXT NOT NULL,
            client_updated_at INTEGER NOT NULL
          )
        ''');

        // 2. 离线同步队列表
        await db.execute('''
          CREATE TABLE sync_queue (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id TEXT NOT NULL,
            progress REAL NOT NULL,
            locator TEXT NOT NULL,
            device_id TEXT NOT NULL,
            device_name TEXT NOT NULL,
            client_updated_at INTEGER NOT NULL,
            retry_count INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
    );
  }

  /// 监听网络状态变更，恢复联网时自动触发队列冲刷
  void _initConnectivityListener() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((results) {
      final hasConnection = results.any((r) => r != ConnectivityResult.none);
      if (hasConnection) {
        flushQueue();
      }
    });
  }

  /// 获取单本书的本地阅读进度（优先离线秒开）
  Future<LocalReadingRecord?> getLocalProgress(String bookId) async {
    final db = await database;
    final res = await db.query(
      'local_progress',
      where: 'book_id = ?',
      whereArgs: [bookId],
      limit: 1,
    );

    if (res.isNotEmpty) {
      return LocalReadingRecord.fromMap(res.first);
    }
    return null;
  }

  /// 保存并同步阅读进度
  /// 1. 立即写入本地 SQLite (保证本地 UI/下次打开即时生效)
  /// 2. 尝试向 Go 后端发送 POST 请求
  /// 3. 若网络失败或超时，自动写入离线队列
  Future<void> saveAndSyncProgress({
    required String bookId,
    required double progress,
    required String locator,
    required String deviceId,
    required String deviceName,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    // 1. 更新本地快照
    await db.insert(
      'local_progress',
      {
        'book_id': bookId,
        'progress': progress,
        'locator': locator,
        'client_updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    // 2. 发起网络请求
    try {
      await _dio.post('/api/v1/sync/progress', data: {
        'book_id': bookId,
        'progress': progress,
        'locator': locator,
        'device_id': deviceId,
        'device_name': deviceName,
        'client_updated_at': now,
      });
    } catch (_) {
      // 3. 网络异常，将任务压入离线队列 (同 book_id 仅保留最新一条队列记录即可)
      await db.delete(
        'sync_queue',
        where: 'book_id = ?',
        whereArgs: [bookId],
      );

      await db.insert(
        'sync_queue',
        {
          'book_id': bookId,
          'progress': progress,
          'locator': locator,
          'device_id': deviceId,
          'device_name': deviceName,
          'client_updated_at': now,
          'retry_count': 0,
        },
      );
    }
  }

  /// 冲刷离线队列：将未同步的任务逐一重放给后端
  Future<void> flushQueue() async {
    if (_isFlushing) return;
    _isFlushing = true;

    try {
      final db = await database;
      final items = await db.query(
        'sync_queue',
        orderBy: 'id ASC',
        limit: 50,
      );

      for (final map in items) {
        final item = SyncQueueItem.fromMap(map);

        try {
          final res = await _dio.post('/api/v1/sync/progress', data: {
            'book_id': item.bookId,
            'progress': item.progress,
            'locator': item.locator,
            'device_id': item.deviceId,
            'device_name': item.deviceName,
            'client_updated_at': item.clientUpdatedAt,
          });

          // 同步成功，或触发了 409 Conflict（服务端数据较新，不需再推），均可移出队列
          if (res.statusCode == 200 || res.statusCode == 201 || res.statusCode == 409) {
            await db.delete('sync_queue', where: 'id = ?', whereArgs: [item.id]);
          }
        } on DioException catch (dioErr) {
          // 409 冲突说明服务端已有更新版本，直接移除该任务
          if (dioErr.response?.statusCode == 409) {
            await db.delete('sync_queue', where: 'id = ?', whereArgs: [item.id]);
          } else if (dioErr.type == DioExceptionType.connectionError ||
                     dioErr.type == DioExceptionType.connectionTimeout) {
            // 依然断网，终止本次遍历，等待下次触发
            break;
          } else {
            // 其他错误递增重试次数，超限剔除
            if (item.retryCount >= 5) {
              await db.delete('sync_queue', where: 'id = ?', whereArgs: [item.id]);
            } else {
              await db.update(
                'sync_queue',
                {'retry_count': item.retryCount + 1},
                where: 'id = ?',
                whereArgs: [item.id],
              );
            }
          }
        }
      }
    } finally {
      _isFlushing = false;
    }
  }

  void dispose() {
    _connectivitySubscription?.cancel();
  }
}