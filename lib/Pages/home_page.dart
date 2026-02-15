import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/photo_item.dart';
import '../services/webdav_service.dart';
import '../widgets/settings_sheet.dart'; // 引入设置组件
import '../widgets/photo_tile.dart'; // 引入照片卡片
import 'home_logic_mixin.dart'; // 引入逻辑 Mixin
import 'photo_view_page.dart';

class SuperBackupPage extends StatefulWidget {
  const SuperBackupPage({super.key});
  @override
  State<SuperBackupPage> createState() => _SuperBackupPageState();
}

// 使用 with 混入逻辑
class _SuperBackupPageState extends State<SuperBackupPage> with HomeLogicMixin {
  int _crossAxisCount = 4;
  double _scale = 1.0;
  int _pointerCount = 0;

  @override
  void initState() {
    super.initState();
    initLogic(); // 调用 Mixin 里的初始化
  }

  // 处理双指缩放手势
  void _handleScaleEnd() {
    int newCount = _crossAxisCount;
    if (_scale > 1.2)
      newCount--;
    else if (_scale < 0.8)
      newCount++;
    newCount = newCount.clamp(2, 6);
    if (newCount != _crossAxisCount) HapticFeedback.selectionClick();
    setState(() {
      _crossAxisCount = newCount;
      _scale = 1.0;
    });
  }

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SettingsSheet(
        urlCtrl: urlCtrl,
        userCtrl: userCtrl,
        passCtrl: passCtrl,
        onSave: () => doBackup(silent: false),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      // 1. 悬浮按钮 (仅非多选模式显示)
      floatingActionButton: (isSelectionMode || isRunning)
          ? null
          : FloatingActionButton.extended(
              onPressed: () => doBackup(silent: false),
              icon: const Icon(Icons.backup_outlined),
              label: const Text("立即备份"),
            ),
      // 2. 底部操作栏 (仅多选模式显示)
      // 修改 home_page.dart 中的 bottomNavigationBar
      bottomNavigationBar: isSelectionMode
          ? BottomAppBar(
              child: Row(
                mainAxisAlignment:
                    MainAxisAlignment.spaceEvenly, // 改回 spaceEvenly 以便排列多个按钮
                children: [
                  // 👇 新增：下载按钮
                  TextButton.icon(
                    onPressed: downloadSelectedToLocal, // 调用 Mixin 中的新方法
                    icon: const Icon(
                      Icons.cloud_download_outlined,
                      color: Colors.blue,
                    ),
                    label: const Text(
                      "保存到本地",
                      style: TextStyle(color: Colors.blue),
                    ),
                  ),

                  // 原有的删除按钮
                  TextButton.icon(
                    onPressed: deleteSelectedCloud,
                    icon: const Icon(Icons.cloud_off, color: Colors.red),
                    label: const Text(
                      "删除云端",
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
            )
          : null,

      // 3. 主体内容
      body: Listener(
        onPointerDown: (_) => setState(() => _pointerCount++),
        onPointerUp: (_) => setState(() => _pointerCount--),
        onPointerCancel: (_) => setState(() => _pointerCount = 0),
        child: GestureDetector(
          onScaleUpdate: (d) {
            if (_pointerCount >= 2)
              setState(() => _scale = d.scale.clamp(0.5, 2.0));
          },
          onScaleEnd: (_) => _handleScaleEnd(),
          child: Transform.scale(
            scale: _scale,
            child: CustomScrollView(
              physics: (_pointerCount >= 2 || _scale != 1.0)
                  ? const NeverScrollableScrollPhysics()
                  : const BouncingScrollPhysics(),
              slivers: [
                // 3.1 顶栏
                SliverAppBar(
                  pinned: true,
                  floating: true,
                  snap: true,
                  backgroundColor: theme.colorScheme.surface,
                  surfaceTintColor: theme.colorScheme.surfaceTint,
                  title: isSelectionMode
                      ? Text("已选 ${selectedIds.length} 张")
                      : const Text(
                          "相册",
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                  leading: isSelectionMode
                      ? IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: exitSelectionMode,
                        )
                      : null,
                  actions: [
                    if (!isSelectionMode) ...[
                      IconButton(
                        onPressed: syncCloudToLocal,
                        icon: const Icon(Icons.sync),
                      ),
                      // 更多操作菜单
                      PopupMenuButton<String>(
                        onSelected: (val) {
                          if (val == 'settings') _showSettings();
                          if (val == 'free_space') freeAllLocalSpace();
                        },
                        itemBuilder: (ctx) => [
                          const PopupMenuItem(
                            value: 'free_space',
                            child: Row(
                              children: [
                                Icon(Icons.cleaning_services_outlined),
                                SizedBox(width: 12),
                                Text('释放本地空间'),
                              ],
                            ),
                          ),
                          const PopupMenuDivider(),
                          const PopupMenuItem(
                            value: 'settings',
                            child: Row(
                              children: [
                                Icon(Icons.settings_outlined),
                                SizedBox(width: 12),
                                Text('连接设置'),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ] else ...[
                      IconButton(
                        onPressed: selectAll,
                        icon: const Icon(Icons.select_all),
                      ),
                    ],
                    const SizedBox(width: 8),
                  ],
                ),

                // 3.2 进度条和日志
                if (isRunning)
                  const SliverToBoxAdapter(child: LinearProgressIndicator()),
                if (logs.isNotEmpty && !isSelectionMode)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                      child: Text(
                        logs.first,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ),
                  ),

                // 3.3 图片列表
                ..._buildGridContent(theme),

                const SliverToBoxAdapter(child: SizedBox(height: 120)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildGridContent(ThemeData theme) {
    List<Widget> slivers = [];
    groupedItems.forEach((date, items) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
            child: Text(
              date,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      );

      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _crossAxisCount,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            delegate: SliverChildBuilderDelegate((_, i) {
              final item = items[i];
              return PhotoTile(
                item: item,
                isSelectionMode: isSelectionMode,
                isSelected: selectedIds.contains(item.id),
                service: WebDavService(
                  url: urlCtrl.text,
                  user: userCtrl.text,
                  pass: passCtrl.text,
                ),
                onLongPress: () {
                  if (!isSelectionMode) {
                    setState(() {
                      isSelectionMode = true;
                      selectedIds.add(item.id);
                      HapticFeedback.selectionClick();
                    });
                  }
                },
                onTap: () {
                  if (isSelectionMode) {
                    toggleSelection(item.id);
                  } else {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PhotoViewer(
                          galleryItems: items,
                          initialIndex: i,
                          service: WebDavService(
                            url: urlCtrl.text,
                            user: userCtrl.text,
                            pass: passCtrl.text,
                          ),
                        ),
                      ),
                    );
                  }
                },
              );
            }, childCount: items.length),
          ),
        ),
      );
    });
    return slivers;
  }
}
