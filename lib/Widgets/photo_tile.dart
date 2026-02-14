import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/photo_item.dart';
import '../services/webdav_service.dart';
import '../widgets/smart_thumbnail.dart';

class PhotoTile extends StatelessWidget {
  final PhotoItem item;
  final bool isSelectionMode;
  final bool isSelected;
  final WebDavService service;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const PhotoTile({
    super.key,
    required this.item,
    required this.isSelectionMode,
    required this.isSelected,
    required this.service,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GestureDetector(
      onLongPress: () {
        onLongPress();
        HapticFeedback.selectionClick();
      },
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          // 选中时显示高亮边框
          border: isSelected
              ? Border.all(color: theme.colorScheme.primary, width: 3)
              : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 1. 缩略图 (选中时稍微缩小)
            Transform.scale(
              scale: isSelected ? 0.9 : 1.0,
              child: SmartThumbnail(item: item, service: service),
            ),

            // 2. 选中模式下的勾选框 (左上角)
            if (isSelectionMode)
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isSelected ? theme.colorScheme.primary : Colors.black26,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(4.0),
                    child: Icon(Icons.check, size: 12, color: Colors.white),
                  ),
                ),
              ),

            // 3. 备份状态标记 (右上角，仅非多选模式显示)
            if (item.isBackedUp && !isSelectionMode)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer.withValues(alpha: 0.8),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    item.asset == null ? Icons.cloud_outlined : Icons.done,
                    size: 14,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}