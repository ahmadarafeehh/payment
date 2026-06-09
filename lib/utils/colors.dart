// lib/utils/color_constants.dart
import 'package:flutter/material.dart';

// ── Original raw constants (used across the whole project) ──────────
const Color webBackgroundColor =
    Color.fromRGBO(200, 200, 200, 1); // Medium gray
const Color mobileSearchColor =
    Color.fromRGBO(220, 220, 220, 1); // Slightly darker gray
const Color blueColor = Colors.grey; // Orange for accents

const Color secondaryColor = Colors.black; // 70% opacity black
const Color mobileBackgroundColor = Color(0xFF121212); // Dark background
const Color primaryColor = Color(0xFFd9d9d9); // Light gray for accents

// ── Unified colour set (dark/light variants) ───────────────────────
class AppColorSet {
  final Color textColor;
  final Color backgroundColor;
  final Color cardColor;
  final Color iconColor;
  final Color dividerColor;
  final Color progressIndicatorColor;
  final Color errorColor;
  final Color gridBackgroundColor;
  final Color gridItemBackgroundColor;
  final Color appBarBackgroundColor;
  final Color hintTextColor;
  final Color borderColor;
  final Color focusedBorderColor;
  final Color skeletonColor;
  final Color avatarBackgroundColor;
  final Color buttonBackgroundColor;
  final Color buttonTextColor;
  final Color dialogBackgroundColor;
  final Color dialogTextColor;
  final Color radioActiveColor;

  const AppColorSet({
    required this.textColor,
    required this.backgroundColor,
    required this.cardColor,
    required this.iconColor,
    required this.dividerColor,
    required this.progressIndicatorColor,
    required this.errorColor,
    required this.gridBackgroundColor,
    required this.gridItemBackgroundColor,
    required this.appBarBackgroundColor,
    required this.hintTextColor,
    required this.borderColor,
    required this.focusedBorderColor,
    required this.skeletonColor,
    required this.avatarBackgroundColor,
    required this.buttonBackgroundColor,
    required this.buttonTextColor,
    required this.dialogBackgroundColor,
    required this.dialogTextColor,
    required this.radioActiveColor,
  });

  // ── Dark theme instance ─────────────────────────────────────────
  factory AppColorSet.dark() => AppColorSet(
        textColor: primaryColor,
        backgroundColor: mobileBackgroundColor,
        cardColor: mobileBackgroundColor,
        iconColor: primaryColor,
        dividerColor: const Color(0xFF333333),
        progressIndicatorColor: primaryColor,
        errorColor: Colors.red,
        gridBackgroundColor: mobileBackgroundColor,
        gridItemBackgroundColor: const Color(0xFF333333),
        appBarBackgroundColor: mobileBackgroundColor,
        hintTextColor: const Color(0xFF666666),
        borderColor: const Color(0xFF333333),
        focusedBorderColor: primaryColor,
        skeletonColor: const Color(0xFF333333).withOpacity(0.6),
        avatarBackgroundColor: const Color(0xFF333333),
        buttonBackgroundColor: const Color(0xFF333333),
        buttonTextColor: primaryColor,
        dialogBackgroundColor: mobileBackgroundColor,
        dialogTextColor: primaryColor,
        radioActiveColor: primaryColor,
      );

  // ── Light theme instance ────────────────────────────────────────
  factory AppColorSet.light() => AppColorSet(
        textColor: Colors.black,
        backgroundColor: Colors.grey[100]!,
        cardColor: Colors.white,
        iconColor: Colors.grey[700]!,
        dividerColor: Colors.grey[300]!,
        progressIndicatorColor: Colors.grey[700]!,
        errorColor: Colors.red,
        gridBackgroundColor: Colors.grey[100]!,
        gridItemBackgroundColor: Colors.grey[300]!,
        appBarBackgroundColor: Colors.grey[100]!,
        hintTextColor: Colors.grey[600]!,
        borderColor: Colors.grey[400]!,
        focusedBorderColor: Colors.black,
        skeletonColor: Colors.grey[300]!.withOpacity(0.6),
        avatarBackgroundColor: Colors.grey[300]!,
        buttonBackgroundColor: Colors.grey[300]!,
        buttonTextColor: Colors.black,
        dialogBackgroundColor: Colors.white,
        dialogTextColor: Colors.black,
        radioActiveColor: Colors.black,
      );
}
