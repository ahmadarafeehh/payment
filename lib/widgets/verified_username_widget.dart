import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:country_flags/country_flags.dart';

// Reusable flag widget for consistent flag display
class CountryFlagWidget extends StatelessWidget {
  final String countryCode;
  final double width;
  final double height;
  final double borderRadius;

  const CountryFlagWidget({
    Key? key,
    required this.countryCode,
    this.width = 16, // Smaller default width
    this.height = 12, // Smaller default height
    this.borderRadius = 2,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final bool hasCountryFlag =
        countryCode.isNotEmpty && countryCode.length == 2;

    if (!hasCountryFlag) {
      return const SizedBox.shrink();
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: width,
        height: height,
        child: CountryFlag.fromCountryCode(
          countryCode,
        ),
      ),
    );
  }
}

class VerifiedUsernameWidget extends StatelessWidget {
  final String username;
  final String uid;
  final TextStyle? style;
  final bool showVerification;
  final String? countryCode;

  const VerifiedUsernameWidget({
    Key? key,
    required this.username,
    required this.uid,
    this.style,
    this.showVerification = true,
    this.countryCode,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (!showVerification && countryCode == null) {
      return Text(username, style: style);
    }

    return FutureBuilder<Map<String, dynamic>?>(
      future: _fetchUserData(uid),
      builder: (context, snapshot) {
        final userData = snapshot.data;
        final isVerified = userData?['isVerified'] == true;

        // Use provided countryCode or fetch from user data
        final String? userCountryCode = countryCode ?? userData?['country'];
        final bool hasCountryFlag = userCountryCode != null &&
            userCountryCode.isNotEmpty &&
            userCountryCode.length == 2;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Username
            Text(username, style: style),
            // Country flag using CountryFlagWidget - BETWEEN USERNAME AND VERIFICATION
            if (hasCountryFlag) ...[
              const SizedBox(width: 4), // Reduced spacing
              CountryFlagWidget(
                countryCode: userCountryCode!,
                width: (style?.fontSize ?? 14) * 0.9, // Smaller scaling
                height: (style?.fontSize ?? 14) * 0.7, // Smaller scaling
              ),
            ],
            // Verification badge
            if (isVerified && showVerification) ...[
              const SizedBox(width: 4),
              Icon(
                Icons.verified,
                color: Colors.blue,
                size: (style?.fontSize ?? 14) * 0.9,
              ),
            ],
          ],
        );
      },
    );
  }

  Future<Map<String, dynamic>?> _fetchUserData(String uid) async {
    try {
      final response = await Supabase.instance.client
          .from('users')
          .select('isVerified, country')
          .eq('uid', uid)
          .single();
      return response;
    } catch (e) {
      return null;
    }
  }
}

// Cached version for better performance in lists
class CachedVerifiedUsernameWidget extends StatelessWidget {
  final String username;
  final bool isVerified;
  final TextStyle? style;
  final String? countryCode;

  const CachedVerifiedUsernameWidget({
    Key? key,
    required this.username,
    required this.isVerified,
    this.style,
    this.countryCode,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final bool hasCountryFlag = countryCode != null &&
        countryCode!.isNotEmpty &&
        countryCode!.length == 2;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Username
        Text(username, style: style),
        // Country flag using CountryFlagWidget - BETWEEN USERNAME AND VERIFICATION
        if (hasCountryFlag) ...[
          const SizedBox(width: 4), // Reduced spacing
          CountryFlagWidget(
            countryCode: countryCode!,
            width: (style?.fontSize ?? 14) * 0.9, // Smaller scaling
            height: (style?.fontSize ?? 14) * 0.7, // Smaller scaling
          ),
        ],
        // Verification badge
        if (isVerified) ...[
          const SizedBox(width: 4),
          Icon(
            Icons.verified,
            color: Colors.blue,
            size: (style?.fontSize ?? 14) * 0.9,
          ),
        ],
      ],
    );
  }
}

// Convenience widget for posts that already have user data
class PostVerifiedUsernameWidget extends StatelessWidget {
  final String username;
  final String uid;
  final TextStyle? style;
  final bool isVerified;
  final String? countryCode;

  const PostVerifiedUsernameWidget({
    Key? key,
    required this.username,
    required this.uid,
    this.style,
    required this.isVerified,
    this.countryCode,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final bool hasCountryFlag = countryCode != null &&
        countryCode!.isNotEmpty &&
        countryCode!.length == 2;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Username
        Text(username, style: style),
        // Country flag using CountryFlagWidget - BETWEEN USERNAME AND VERIFICATION
        if (hasCountryFlag) ...[
          const SizedBox(width: 4), // Reduced spacing
          CountryFlagWidget(
            countryCode: countryCode!,
            width: (style?.fontSize ?? 14) * 0.9, // Smaller scaling
            height: (style?.fontSize ?? 14) * 0.7, // Smaller scaling
          ),
        ],
        // Verification badge
        if (isVerified) ...[
          const SizedBox(width: 4),
          Icon(
            Icons.verified,
            color: Colors.blue,
            size: (style?.fontSize ?? 14) * 0.9,
          ),
        ],
      ],
    );
  }
}

// Additional reusable widget for username with flag (similar to what we used in profile)
class UsernameWithFlag extends StatelessWidget {
  final String username;
  final bool isVerified;
  final String? countryCode;
  final TextStyle? style;
  final double flagSize;
  final bool showVerification;

  const UsernameWithFlag({
    Key? key,
    required this.username,
    required this.isVerified,
    this.countryCode,
    this.style,
    this.flagSize = 12, // Smaller default flag size
    this.showVerification = true,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final bool hasCountryFlag = countryCode != null &&
        countryCode!.isNotEmpty &&
        countryCode!.length == 2;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Username
        Text(username, style: style),
        // Country flag - BETWEEN USERNAME AND VERIFICATION
        if (hasCountryFlag) ...[
          const SizedBox(width: 4), // Reduced spacing
          CountryFlagWidget(
            countryCode: countryCode!,
            width: flagSize * 1.33, // Maintain aspect ratio
            height: flagSize,
          ),
        ],
        // Verification badge
        if (isVerified && showVerification) ...[
          const SizedBox(width: 4),
          Icon(
            Icons.verified,
            color: Colors.blue,
            size: (style?.fontSize ?? 14) * 0.9,
          ),
        ],
      ],
    );
  }
}
