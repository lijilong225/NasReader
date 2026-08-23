import 'package:flutter/material.dart';
import 'package:dio/dio.dart';

import 'pages/file_browser_page.dart';
import 'pages/local_bookshelf_page.dart';
import 'pages/settings_page.dart';

class MainNavigationContainer extends StatefulWidget {
  final Dio dio;
  final ValueNotifier<ThemeMode>? themeNotifier;

  const MainNavigationContainer({
    super.key,
    required this.dio,
    this.themeNotifier,
  });

  @override
  State<MainNavigationContainer> createState() => _MainNavigationContainerState();
}

class _MainNavigationContainerState extends State<MainNavigationContainer> {
  int _currentIndex = 0;

  // 挂载 Key 用于 Tab 切换时联动刷新
  final GlobalKey<LocalBookshelfPageState> _bookshelfKey = GlobalKey<LocalBookshelfPageState>();
  // 用于在切到设置页时主动触发缓存统计刷新
  final GlobalKey<SettingsPageState> _settingsKey = GlobalKey<SettingsPageState>();

  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _pages = [
      LocalBookshelfPage(
        key: _bookshelfKey, // 👈 绑定 Key
        dio: widget.dio,
      ),
      FileBrowserPage(dio: widget.dio),
      SettingsPage(
        key: _settingsKey,
        dio: widget.dio,
        themeNotifier: widget.themeNotifier,
      ),
    ];
  }

  void _onTabTapped(int index) {
    setState(() {
      _currentIndex = index;
    });

    // 1. 切到「本地书架」(index = 0) 时自动重新扫描目录
    if (index == 0) {
      _bookshelfKey.currentState?.loadLocalBooks();
    }
    // 当用户切回「系统设置」Tab (index = 2) 时，自动刷新缓存大小
    if (index == 2) {
      _settingsKey.currentState?.calculateCacheSize();
    }
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
        onTap: _onTabTapped,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Theme.of(context).colorScheme.primary,
        unselectedItemColor: Colors.grey,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.book_outlined),
            activeIcon: Icon(Icons.book),
            label: '本地书架',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.cloud_outlined),
            activeIcon: Icon(Icons.cloud),
            label: 'NAS 书库',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            activeIcon: Icon(Icons.settings),
            label: '系统设置',
          ),
        ],
      ),
    );
  }
}