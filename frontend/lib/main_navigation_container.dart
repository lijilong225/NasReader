import 'package:flutter/material.dart';
import 'package:dio/dio.dart';

import 'pages/local_bookshelf_page.dart';
import 'pages/file_browser_page.dart';
import 'pages/settings_page.dart';

class MainNavigationContainer extends StatefulWidget {
  final Dio dio;

  const MainNavigationContainer({super.key, required this.dio});

  @override
  State<MainNavigationContainer> createState() => _MainNavigationContainerState();
}

class _MainNavigationContainerState extends State<MainNavigationContainer> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = [
      LocalBookshelfPage(dio: widget.dio),
      FileBrowserPage(dio: widget.dio),
      SettingsPage(dio: widget.dio),
    ];

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (int index) {
          setState(() => _currentIndex = index);
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