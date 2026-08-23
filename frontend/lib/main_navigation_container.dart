import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import './pages/local_bookshelf_page.dart';
import './pages/file_browser_page.dart';

class MainNavigationContainer extends StatefulWidget {
  final Dio dio;

  const MainNavigationContainer({super.key, required this.dio});

  @override
  State<MainNavigationContainer> createState() => _MainNavigationContainerState();
}

class _MainNavigationContainerState extends State<MainNavigationContainer> {
  int _currentIndex = 0;
  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    // 将已缓存书架与 NAS 远程书库放入 Tab 容器
    _pages = [
      LocalBookshelfPage(dio: widget.dio),
      FileBrowserPage(dio: widget.dio),
      SettingsPage(dio: _dio),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        type: BottomNavigationBarType.fixed,
        onTap: (index) {
          // 点击第 4 个 Item（索引 3）时弹出日志浮窗，不切换主 Tab
          if (index == 3) {
            AppLogger.showLogModal(context);
            return;
          }
          setState(() => _currentIndex = index);
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.book),
            label: '本地书架',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.cloud_queue),
            label: 'NAS 书库',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: '设置',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.bug_report, color: Colors.orange),
            label: '网络日志',
          ),
        ],
      ),
    );
  }
}