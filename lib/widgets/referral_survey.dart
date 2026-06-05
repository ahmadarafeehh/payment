// lib/widgets/referral_survey.dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum ReferralSource { friend, google, tiktok, other }

/// Shows a modal bottom sheet that asks “How did you hear about us?”
/// On submit it inserts the response into `user_referral_survey`.
class ReferralSurvey extends StatefulWidget {
  final String uid;
  final VoidCallback onComplete;

  const ReferralSurvey({
    Key? key,
    required this.uid,
    required this.onComplete,
  }) : super(key: key);

  @override
  State<ReferralSurvey> createState() => _ReferralSurveyState();
}

class _ReferralSurveyState extends State<ReferralSurvey> {
  ReferralSource? _selectedSource;
  final _otherController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _submitting = false;

  @override
  void dispose() {
    _otherController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_selectedSource == null) return;
    if (_selectedSource == ReferralSource.other &&
        _otherController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please tell us how you found us')),
      );
      return;
    }

    setState(() => _submitting = true);

    try {
      await Supabase.instance.client.from('user_referral_survey').insert({
        'uid': widget.uid,
        'source': _selectedSource!.name,
        'other_detail': _selectedSource == ReferralSource.other
            ? _otherController.text.trim()
            : null,
      });
      widget.onComplete();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 24,
        right: 24,
        top: 32,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'How did you hear about us?',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              _buildOption(ReferralSource.friend, '👥 From a friend'),
              _buildOption(ReferralSource.google, '🔍 Google search'),
              _buildOption(ReferralSource.tiktok, '🎵 TikTok'),
              _buildOption(ReferralSource.other, '✏️ Other'),
              if (_selectedSource == ReferralSource.other) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _otherController,
                  decoration: const InputDecoration(
                    hintText: 'Please specify',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (_selectedSource == ReferralSource.other &&
                        (value == null || value.trim().isEmpty)) {
                      return 'This field is required';
                    }
                    return null;
                  },
                ),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _submitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: _submitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Submit'),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOption(ReferralSource source, String label) {
    final isSelected = _selectedSource == source;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => setState(() => _selectedSource = source),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey.shade400,
              width: isSelected ? 2 : 1,
            ),
            color: isSelected
                ? Theme.of(context).colorScheme.primary.withOpacity(0.05)
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}
