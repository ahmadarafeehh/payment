import 'package:flutter/material.dart';

/// Tappable Agree / Disagree control with live counts.
/// Use on the main post (RatingSection) where the current user casts a vote.
///
/// Visual language deliberately avoids thumb icons: check / x pills instead,
/// so it doesn't read as "like / dislike".
class AgreeDisagreeButtons extends StatelessWidget {
  final int agreeCount;
  final int disagreeCount;
  /// null = user hasn't voted, 'agree' or 'disagree' = current vote.
  final String? userChoice;
  final ValueChanged<String> onChoice; // passes 'agree' or 'disagree'
  final bool isLoading;

  const AgreeDisagreeButtons({
    Key? key,
    required this.agreeCount,
    required this.disagreeCount,
    required this.userChoice,
    required this.onChoice,
    this.isLoading = false,
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
          active: userChoice == 'agree',
          onTap: isLoading ? null : () => onChoice('agree'),
        ),
        const SizedBox(width: 10),
        _Pill(
          icon: Icons.close_rounded,
          label: 'Disagree',
          count: disagreeCount,
          color: _disagreeColor,
          active: userChoice == 'disagree',
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
  final VoidCallback? onTap;

  const _Pill({
    required this.icon,
    required this.label,
    required this.count,
    required this.color,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: active ? color.withOpacity(0.18) : Colors.black.withOpacity(0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: active ? color.withOpacity(0.8) : Colors.white.withOpacity(0.12),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 16,
                color: active ? color : Colors.white.withOpacity(0.75),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: active ? color : Colors.white.withOpacity(0.85),
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 5),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 12,
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

/// Read-only ✓ / ✗ badge for showing ONE specific user's choice —
/// used in the reactions list where each row belongs to a different person.
/// Renders nothing if the user made no choice.
class AgreeDisagreeBadge extends StatelessWidget {
  final String? choice; // 'agree', 'disagree', or null

  const AgreeDisagreeBadge({Key? key, required this.choice}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (choice != 'agree' && choice != 'disagree') {
      return const SizedBox.shrink();
    }
    final bool isAgree = choice == 'agree';
    final Color color =
        isAgree ? const Color(0xFF4ADE80) : const Color(0xFFF87171);
    final IconData icon = isAgree ? Icons.check_rounded : Icons.close_rounded;

    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withOpacity(0.18),
        border: Border.all(color: color.withOpacity(0.8), width: 1),
      ),
      child: Icon(icon, size: 14, color: color),
    );
  }
}
