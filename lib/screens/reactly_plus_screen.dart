import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:Ratedly/services/iap_service.dart';
import 'package:Ratedly/utils/theme_provider.dart';

class ReactlyPlusScreen extends StatefulWidget {
  const ReactlyPlusScreen({Key? key}) : super(key: key);

  @override
  State<ReactlyPlusScreen> createState() => _ReactlyPlusScreenState();
}

class _ReactlyPlusScreenState extends State<ReactlyPlusScreen> {
  final IAPService _iap = IAPService();
  StoreProduct? _product;
  bool _isLoading = true;
  bool _isPurchased = false;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final results = await Future.wait([
        _iap.isPurchased(),
        _iap.getProduct(),
      ]);
      if (mounted) {
        setState(() {
          _isPurchased = results[0] as bool;
          _product = results[1] as StoreProduct?;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load product: $e')),
        );
      }
    }
  }

  Future<void> _handlePurchase() async {
    if (_isProcessing) return;
    if (_product == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Product not available. Try again later.')),
      );
      return;
    }
    setState(() => _isProcessing = true);
    try {
      final success = await _iap.buyProduct(_product!);
      if (mounted) {
        setState(() => _isPurchased = success);
        if (success) {
          _showSuccessDialog();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Purchase failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.amber.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.workspace_premium,
                  color: Colors.amber, size: 48),
            ),
            const SizedBox(height: 20),
            const Text(
              'Reactly+ Activated!',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              'You now enjoy an ad-free experience.',
              style: TextStyle(fontSize: 15),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.blue.withOpacity(0.3)),
              ),
              child: Row(
                children: const [
                  Icon(Icons.verified, color: Colors.blue, size: 22),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Our team will reach out to you through Reactly within 2 hours to verify your account.',
                      style: TextStyle(fontSize: 13, color: Colors.blue),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                ),
                child: const Text(
                  'Got it!',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleRestore() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);
    try {
      final restored = await _iap.restorePurchases();
      if (mounted) {
        setState(() => _isPurchased = restored);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              restored
                  ? 'Purchases restored successfully!'
                  : 'No previous purchases found.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restore failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDark = themeProvider.themeMode == ThemeMode.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final bgColor = isDark ? Colors.grey[900]! : Colors.grey[100]!;
    final cardColor = isDark ? Colors.grey[850]! : Colors.white;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: const Text('Reactly+'),
        backgroundColor: bgColor,
        elevation: 0,
        foregroundColor: textColor,
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: Colors.amber))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Icon(Icons.workspace_premium,
                      size: 80, color: Colors.amber),
                  const SizedBox(height: 16),
                  Text(
                    'Unlock Premium Features',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Monthly subscription · Full feature access',
                    style: TextStyle(
                      fontSize: 14,
                      color: textColor.withOpacity(0.5),
                    ),
                  ),
                  const SizedBox(height: 32),
                  _buildBenefitTile(
                    icon: Icons.block,
                    title: 'No Ads',
                    description: 'Enjoy a completely ad-free experience',
                    textColor: textColor,
                    cardColor: cardColor,
                  ),
                  _buildBenefitTile(
                    icon: Icons.verified,
                    title: 'Apply for Verification',
                    description:
                        'Get the blue checkmark — our team will reach out within 2 hours',
                    textColor: textColor,
                    cardColor: cardColor,
                  ),
                  const SizedBox(height: 48),
                  if (_isPurchased)
                    _buildActiveBadge()
                  else ...[
                    _buildPurchaseButton(textColor),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: _isProcessing ? null : _handleRestore,
                      child: Text(
                        'Restore Purchases',
                        style: TextStyle(color: textColor.withOpacity(0.6)),
                      ),
                    ),
                  ],
                  const SizedBox(height: 32),
                  Text(
                    'Payment will be charged to your Apple ID.\nManaged through the App Store.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: textColor.withOpacity(0.4),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildActiveBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        color: Colors.green.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.green, width: 1.5),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.check_circle, color: Colors.green, size: 28),
          SizedBox(width: 12),
          Text(
            'Reactly+ Active',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.green,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPurchaseButton(Color textColor) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _isProcessing ? null : _handlePurchase,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.amber,
          foregroundColor: Colors.black,
          disabledBackgroundColor: Colors.amber.withOpacity(0.5),
          padding: const EdgeInsets.symmetric(vertical: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
          elevation: 0,
        ),
        child: _isProcessing
            ? const SizedBox(
                height: 22,
                width: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: Colors.black),
              )
            : Text(
                _product != null
                    ? 'Upgrade for ${_product!.priceString}'
                    : 'Upgrade — \$0.99',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
      ),
    );
  }

  Widget _buildBenefitTile({
    required IconData icon,
    required String title,
    required String description,
    required Color textColor,
    required Color cardColor,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.amber.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: Colors.amber, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 14,
                    color: textColor.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.check_circle_outline,
              color: Colors.amber.withOpacity(0.8), size: 22),
        ],
      ),
    );
  }
}
