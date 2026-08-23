import 'package:flutter/foundation.dart';

class AppLogger {
  static final ValueNotifier<List<String>> logs = ValueNotifier([]);

  static void log(String message) {
    debugPrint(message);
    final now = DateTime.now();
    final timeStr =
        "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
    final entry = "[$timeStr] $message";
    logs.value = [entry, ...logs.value.take(200)]; // 最多保留最新 200 条
  }

  static void clear() {
    logs.value = [];
  }

  /// 弹出底部网络日志查看抽屉
  static void showLogModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Container(
          height: MediaQuery.of(ctx).size.height * 0.8,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.terminal, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'HTTP 网络日志',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        tooltip: '清空日志',
                        onPressed: AppLogger.clear,
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ],
              ),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Expanded(
                child: ValueListenableBuilder<List<String>>(
                  valueListenable: AppLogger.logs,
                  builder: (context, list, _) {
                    if (list.isEmpty) {
                      return const Center(
                        child: Text(
                          '暂无网络请求日志\n发起的 API 会在此实时显示',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey, height: 1.5),
                        ),
                      );
                    }
                    return ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, index) {
                        final text = list[index];
                        Color color = Colors.black87;
                        if (text.contains('❌') || text.contains('404') || text.contains('500')) {
                          color = Colors.red.shade700;
                        } else if (text.contains('✅') || text.contains('200')) {
                          color = Colors.green.shade700;
                        } else if (text.contains('🚀')) {
                          color = Colors.blue.shade700;
                        }

                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: SelectableText(
                            text,
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              color: color,
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}