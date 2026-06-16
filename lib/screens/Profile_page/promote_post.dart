// lib/screens/Profile_page/promote_post.dart
import 'package:flutter/material.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:Ratedly/services/post_boost_service.dart';
import 'package:Ratedly/utils/utils.dart';

// =============================================================================
// PROMOTE POST BUTTON
// =============================================================================
class PromotePostButton extends StatefulWidget {
  final String postId;
  final bool initialIsBoosted;

  const PromotePostButton({
    Key? key,
    required this.postId,
    this.initialIsBoosted = false,
  }) : super(key: key);

  @override
  State<PromotePostButton> createState() => _PromotePostButtonState();
}

class _PromotePostButtonState extends State<PromotePostButton> {
  late bool _isBoosted;

  @override
  void initState() {
    super.initState();
    _isBoosted = widget.initialIsBoosted;
  }

  @override
  Widget build(BuildContext context) {
    if (_isBoosted) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('🔥', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
              Text(
                'Boosted',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.75),
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: GestureDetector(
        onTap: () async {
          final result = await showPromotePostSheet(
            context,
            postId: widget.postId,
          );
          if (result == true && mounted) {
            setState(() => _isBoosted = true);
          }
        },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFFF6B35), Color(0xFFFF9248)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFF6B35).withOpacity(0.30),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('🔥', style: TextStyle(fontSize: 16)),
              SizedBox(width: 8),
              Text(
                'Increase Reactions',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  letterSpacing: 0.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// PROMOTE POST BOTTOM SHEET
// Returns true via Navigator.pop if the boost purchase succeeded.
// =============================================================================
Future<bool?> showPromotePostSheet(
  BuildContext context, {
  required String postId,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => _PromotePostSheet(postId: postId),
  );
}

// =============================================================================
// SHEET STATE
// =============================================================================
enum _SheetState {
  /// Product is being fetched from RevenueCat — CTA shows a spinner.
  loading,

  /// Product fetched successfully — CTA shows price and is tappable.
  ready,

  /// Product not found or RevenueCat error — CTA is disabled with label.
  unavailable,

  /// Purchase is in progress (Apple payment sheet is open).
  purchasing,
}

class _PromotePostSheet extends StatefulWidget {
  final String postId;
  const _PromotePostSheet({required this.postId});

  @override
  State<_PromotePostSheet> createState() => _PromotePostSheetState();
}

class _PromotePostSheetState extends State<_PromotePostSheet> {
  final PostBoostService _boostService = PostBoostService();

  _SheetState _sheetState = _SheetState.loading;
  StoreProduct? _product;

  @override
  void initState() {
    super.initState();
    _loadProduct();
  }

  Future<void> _loadProduct() async {
    // Sheet is already showing "loading" spinner in the CTA — fetch quietly.
    final product = await _boostService.getBoostProduct();
    if (!mounted) return;
    setState(() {
      _product = product;
      _sheetState =
          product != null ? _SheetState.ready : _SheetState.unavailable;
    });
  }

  Future<void> _onPromoteTap() async {
    if (_product == null || _sheetState != _SheetState.ready) return;

    setState(() => _sheetState = _SheetState.purchasing);

    try {
      final success = await _boostService.buyBoost(
        postId: widget.postId,
        product: _product!,
      );

      if (!mounted) return;

      if (success) {
        Navigator.pop(context, true);
        showSnackBar(context, 'Your post has been boosted! 🔥');
      } else {
        // User cancelled — silently return to ready state.
        setState(() => _sheetState = _SheetState.ready);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _sheetState = _SheetState.ready);
      showSnackBar(context, 'Something went wrong. Please try again.');
    }
  }

  // ── CTA label / content ────────────────────────────────────────────────────

  Widget _buildCtaChild() {
    switch (_sheetState) {
      case _SheetState.loading:
      case _SheetState.purchasing:
        return const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
        );
      case _SheetState.unavailable:
        return const Text(
          'Currently Unavailable',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        );
      case _SheetState.ready:
        return Text(
          'Promote for ${_product!.priceString}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
        );
    }
  }

  bool get _ctaTappable => _sheetState == _SheetState.ready;

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        MediaQuery.of(context).padding.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Drag handle
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 8),

          // Icon
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [Color(0xFFFF6B35), Color(0xFFFF9248)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFF6B35).withOpacity(0.35),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: const Center(
              child: Text('🔥', style: TextStyle(fontSize: 32)),
            ),
          ),
          const SizedBox(height: 20),

          // Title
          const Text(
            'Promote Your Post',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.1,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),

          // Description
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Give your post a boost. We\'ll show it to more people in the '
              'feed until it earns '
              '${PostBoostService.targetNewReactions} new reactions.',
              style: TextStyle(
                color: Colors.white.withOpacity(0.55),
                fontSize: 14,
                height: 1.55,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),

          // Feature list
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.06)),
            ),
            child: Column(
              children: [
                _FeatureRow(
                  icon: Icons.trending_up_rounded,
                  text:
                      'Shown to more people until ${PostBoostService.targetNewReactions} new reactions',
                ),
                const SizedBox(height: 14),
                const _FeatureRow(
                  icon: Icons.visibility_rounded,
                  text: 'Higher placement in the feed ranking',
                ),
                const SizedBox(height: 14),
                const _FeatureRow(
                  icon: Icons.flash_on_rounded,
                  text: 'Boost applies immediately',
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          // CTA button — state-driven, no separate error text block
          GestureDetector(
            onTap: _ctaTappable ? _onPromoteTap : null,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: _sheetState == _SheetState.unavailable ? 0.45 : 1.0,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFF6B35), Color(0xFFFF9248)],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: _ctaTappable
                      ? [
                          BoxShadow(
                            color: const Color(0xFFFF6B35).withOpacity(0.35),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ]
                      : [],
                ),
                child: Center(child: _buildCtaChild()),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Cancel
          GestureDetector(
            onTap: _sheetState == _SheetState.purchasing
                ? null
                : () => Navigator.pop(context, false),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Not Now',
                style: TextStyle(
                  color: Colors.white
                      .withOpacity(_sheetState == _SheetState.purchasing ? 0.2 : 0.45),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// FEATURE ROW
// =============================================================================
class _FeatureRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _FeatureRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: const Color(0xFFFF6B35).withOpacity(0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: const Color(0xFFFF9248), size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: Colors.white.withOpacity(0.85),
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}
