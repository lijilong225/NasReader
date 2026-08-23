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
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
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
        ],
      ),
    );
  }
}