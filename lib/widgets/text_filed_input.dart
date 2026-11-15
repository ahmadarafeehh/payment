import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TextFieldInput extends StatelessWidget {
  final TextEditingController textEditingController;
  final bool isPass;
  final String hintText;
  final TextInputType textInputType;
  final TextStyle? hintStyle;
  final Color? fillColor;
  final List<TextInputFormatter>? inputFormatters;
  final FocusNode? focusNode; // ADD THIS
  final TextStyle? textStyle; // NEW: optional override for the typed text

  const TextFieldInput({
    Key? key,
    required this.textEditingController,
    this.isPass = false,
    required this.hintText,
    required this.textInputType,
    this.hintStyle,
    this.fillColor,
    this.inputFormatters,
    this.focusNode, // ADD THIS
    this.textStyle, // NEW
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: textEditingController,
      focusNode: focusNode, // ADD THIS
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: hintStyle,
        filled: true,
        fillColor: fillColor,
        contentPadding: const EdgeInsets.all(12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      keyboardType: textInputType,
      obscureText: isPass,
      // NEW: falls back to the original style when no textStyle is passed,
      // so every other screen using TextFieldInput looks exactly as before.
      style: textStyle ??
          const TextStyle(
            color: Colors.white,
            fontFamily: 'Inter',
          ),
      inputFormatters: inputFormatters,
    );
  }
}
