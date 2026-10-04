import 'package:flutter/material.dart';

/// Onglet de [AppNavBar] : icône, icône sélectionnée (facultative) et libellé.
class AppNavItem {
  final Widget icon;
  final Widget? selectedIcon;
  final String label;
  const AppNavItem({required this.icon, this.selectedIcon, required this.label});
}

/// Barre de navigation du bas aux dimensions fixes : chaque onglet a la même largeur, l'icône est dans
/// une case de 24 px au même endroit pour tous, et le libellé tient toujours sur une ligne (réduit si
/// besoin). Les icônes restent ainsi alignées quel que soit le téléphone ou la longueur des libellés.
class AppNavBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final List<AppNavItem> items;

  const AppNavBar({super.key, required this.selectedIndex, required this.onSelected, required this.items});

  static const double height = 64;
  static const double iconSize = 24;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      elevation: 3,
      shadowColor: Colors.black26,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: height,
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(child: _Tab(item: items[i], selected: i == selectedIndex, onTap: () => onSelected(i))),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final AppNavItem item;
  final bool selected;
  final VoidCallback onTap;

  const _Tab({required this.item, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      selected: selected,
      button: true,
      label: item.label,
      child: InkResponse(
        onTap: onTap,
        radius: 36,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Pastille de sélection de taille fixe : l'icône (et son éventuel badge) est centrée dedans.
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              width: 56,
              height: 30,
              decoration: BoxDecoration(
                color: selected ? scheme.primary.withValues(alpha: 0.12) : Colors.transparent,
                borderRadius: BorderRadius.circular(15),
              ),
              alignment: Alignment.center,
              child: IconTheme.merge(
                data: IconThemeData(size: AppNavBar.iconSize, color: color),
                child: SizedBox.square(
                  dimension: AppNavBar.iconSize,
                  child: Center(child: selected ? (item.selectedIcon ?? item.icon) : item.icon),
                ),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 16,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    item.label,
                    maxLines: 1,
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      fontSize: 12,
                      height: 1.2,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                      color: color,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
