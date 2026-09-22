import 'package:flutter/material.dart';

/// Tappable Agree / Disagree control for a SPECIFIC reaction row.
/// Any viewer (including the reaction's own author) can tap these to
/// vote on whether they agree/disagree with that person's reaction.
///
/// Visual language deliberately avoids thumb icons: check / x pills instead,
/// so it doesn't read as "like / dislike".
class AgreeDisagreeButtons extends StatelessWidget {
  final int agreeCount;
  final int disagreeCount;
  /// null = viewer hasn't voted on this reaction, 'agree'/'disagree' = current vote.
  final String? viewerChoice;
  final ValueChanged<String> onChoice; // passes 'agree' or 'disagree'
  final bool isLoading;
  final bool compact; // smaller sizing for list rows

  const AgreeDisagreeButtons({
    Key? key,
    required this.agreeCount,
    required this.disagreeCount,
    required this.viewerChoice,
    required this.onChoice,
    this.isLoading = false,
    this.compact = false,
  }) : super(key: key);

  static const Color _agreeColor = Color(0xFF4ADE80); // green
  static const Color _disagreeColor = Color(0xFFF87171); // red

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Pill(
          icon: Icons.check_rounded,
          label: 'Agree',
          count: agreeCount,
          color: _agreeColor,
          active: viewerChoice == 'agree',
          compact: compact,
          onTap: isLoading ? null : () => onChoice('agree'),
        ),
        SizedBox(width: compact ? 6 : 10),
        _Pill(
          icon: Icons.close_rounded,
          label: 'Disagree',
          count: disagreeCount,
          color: _disagreeColor,
          active: viewerChoice == 'disagree',
          compact: compact,
          onTap: isLoading ? null : () => onChoice('disagree'),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  final Color color;
  final bool active;
  final bool compact;
  final VoidCallback? onTap;

  const _Pill({
    required this.icon,
    required this.label,
    required this.count,
    required this.color,
    required this.active,
    required this.compact,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final double hPad = compact ? 9 : 12;
    final double vPad = compact ? 5 : 7;
    final double iconSize = compact ? 13 : 16;
    final double fontSize = compact ? 11 : 12;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
          decoration: BoxDecoration(
            color: active
                ? color.withOpacity(0.18)
                : Colors.black.withOpacity(0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color:
                  active ? color.withOpacity(0.8) : Colors.white.withOpacity(0.12),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: iconSize,
                color: active ? color : Colors.white.withOpacity(0.75),
              ),
              if (!compact) ...[
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w600,
                    color: active ? color : Colors.white.withOpacity(0.85),
                  ),
                ),
              ],
              if (count > 0) ...[
                SizedBox(width: compact ? 4 : 5),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w700,
                    color: active ? color : Colors.white.withOpacity(0.6),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
