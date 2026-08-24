// lib/widgets/reader_drawer.dart
import 'package:flutter/material.dart';
import '../models/bookmark_model.dart';

class ReaderDrawer extends StatefulWidget {
  final String title;
  final Widget tocView;
  final List<Bookmark> bookmarks;
  final Function(Bookmark) onBookmarkTap;
  final Function(Bookmark) onBookmarkDelete;

  const ReaderDrawer({
    super.key,
    required this.title,
    required this.tocView,
    required this.bookmarks,
    required this.onBookmarkTap,
    required this.onBookmarkDelete,
  });

  @override
  State<ReaderDrawer> createState() => _ReaderDrawerState();
}

class _ReaderDrawerState extends State<ReaderDrawer> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: Column(
        children: [
          Container(
            color: const Color(0xFF382E25),
            child: SafeArea(
              bottom: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      widget.title,
                      style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TabBar(
                    controller: _tabController,
                    indicatorColor: const Color(0xFF8D7358),
                    labelColor: Colors.white,
                    unselectedLabelColor: Colors.white60,
                    tabs: [
                      const Tab(text: '目录'),
                      Tab(text: '书签 (${widget.bookmarks.length})'),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                widget.tocView,
                _buildBookmarkList(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBookmarkList() {
    if (widget.bookmarks.isEmpty) {
      return const Center(child: Text('暂无书签记录', style: TextStyle(color: Colors.grey, fontSize: 13)));
    }

    return ListView.separated(
      itemCount: widget.bookmarks.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final b = widget.bookmarks[index];
        return Dismissible(
          key: ValueKey(b.id),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Colors.redAccent,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 16),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          onDismissed: (_) => widget.onBookmarkDelete(b),
          child: ListTile(
            dense: true,
            title: Text(
              b.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (b.snippet.isNotEmpty)
                  Text(
                    b.snippet,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.black54),
                  ),
                const SizedBox(height: 2),
                Text(
                  '${(b.progressPercent * 100).toStringAsFixed(1)}% · ${b.createdAt.month}-${b.createdAt.day} ${b.createdAt.hour.toString().padLeft(2, '0')}:${b.createdAt.minute.toString().padLeft(2, '0')}',
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ],
            ),
            onTap: () => widget.onBookmarkTap(b),
          ),
        );
      },
    );
  }
}