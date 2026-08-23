import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import './pages/local_bookshelf_page.dart';
import './pages/file_browser_page.dart';
import './pages/settings_page.dart';

class MainNavigationContainer extends StatefulWidget {
  const MainNavigationContainer({super.key});

  @override
  State<MainNavigationContainer> createState() => _MainNavigationContainerState();
}

class _MainNavigationContainerState extends State<MainNavigationContainer> {
  int _currentIndex = 0;
  late final Dio _dio;

  @override
  void initState() {
    super.initState();
    _dio = NetworkClient.getDio();
  }

  @override
  Widget build(BuildContext context) {
    // 对应 3 个主要页面
    final pages = [
      LocalBookshelfPage(dio: _dio),
      FileBrowserPage(dio: _dio),
      SettingsPage(dio: _dio),
    ];

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (int index) {
          setState(() {
            _currentIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.book_outlined),
            selectedIcon: Icon(Icons.book),
            label: '本地书架',
          ),
          NavigationDestination(
            icon: Icon(Icons.cloud_outlined),
            selectedIcon: Icon(Icons.cloud),
            label: 'NAS 书库',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}