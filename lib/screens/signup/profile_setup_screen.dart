import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/resources/auth_methods.dart';
import 'package:Ratedly/responsive/mobile_screen_layout.dart';
import 'package:Ratedly/responsive/responsive_layout.dart';
import 'package:Ratedly/utils/utils.dart';
import 'package:Ratedly/widgets/text_filed_input.dart';
import 'package:Ratedly/services/analytics_service.dart'; // ✅ screen tracking
import 'package:Ratedly/services/debug_logger.dart'; // NEW
import 'package:Ratedly/services/device_session.dart'; // NEW

class ProfileSetupScreen extends StatefulWidget {
  final DateTime dateOfBirth;
  final VoidCallback onComplete;

  const ProfileSetupScreen({
    Key? key,
    required this.dateOfBirth,
    required this.onComplete,
  }) : super(key: key);

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

// Fix #2: only lets a-z, 0-9, ., _ ever land in the field — no reject-and-flash-red
// for a keystroke the user hasn't finished typing. Uppercase is silently
// lowercased instead of rejected, matching Instagram/TikTok behavior.
class _UsernameFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final lowered = newValue.text.toLowerCase();
    final filtered = lowered.replaceAll(RegExp(r'[^a-z0-9_.]'), '');
    if (filtered == newValue.text) return newValue;

    // Keep the cursor at the same relative position after stripping/lowering.
    final delta = newValue.text.length - filtered.length;
    final newOffset = (newValue.selection.end - delta).clamp(0, filtered.length);
    return TextEditingValue(
      text: filtered,
      selection: TextSelection.collapsed(offset: newOffset),
    );
  }
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen>
    with WidgetsBindingObserver {
  // Versioned + device-scoped, matching the app's existing SharedPreferences
  // key convention (e.g. auth_cache_v4_<uid>). No uid exists yet at this
  // pre-auth screen, so DeviceSession.id is the scoping key instead —
  // consistent with how this file already scopes its debug/analytics events.
  static const _draftKeyPrefix = 'profile_setup_draft_v1';

  final TextEditingController _usernameController = TextEditingController();
  bool _isLoading = false;
  String? _selectedGender;
  String? _usernameError;
  int _usernameLength = 0;
  bool _submitAttempted = false; // Fix #3/#4: only show "required" nudges after a tap
  bool _draftRestored = false;

  final List<String> _genders = ['Male', 'Female'];

  @override
  void initState() {
    super.initState();
    AnalyticsService.screenEnter('profile_setup');
    WidgetsBinding.instance.addObserver(this); // Fix #5: catch backgrounding

    // Fix #2: debounce structural validation instead of validating on every
    // keystroke. Character-set enforcement now happens via the formatter, so
    // this listener only checks shape rules (length, consecutive punctuation)
    // and does so after a short pause in typing — the error text under the
    // field only appears once the user stops typing for 800ms, not on every
    // keystroke.
    _usernameController.addListener(_onUsernameChanged);

    _restoreDraft(); // Fix #5

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final deviceId = await DeviceSession.id;
      DebugLogger.logEvent('SCREEN_ENTERED', 'profile_setup deviceId=$deviceId');
    });
  }

  Timer? _debounce;
  void _onUsernameChanged() {
    _saveDraft(); // Fix #5: persist on every change, not just on background
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      final username = _usernameController.text;
      setState(() {
        _usernameLength = username.length;
        _usernameError = _validateUsernameText(username);
      });
    });
    // Keep the character counter live even before the debounce fires.
    setState(() => _usernameLength = _usernameController.text.length);
  }

  // Fix #5: persist and restore draft state across app backgrounding / kills.
  // Keys are scoped by DeviceSession.id (no uid exists pre-auth), same
  // resolution this file already uses for its debug/analytics events.
  Future<String> _usernameKey() async =>
      '${_draftKeyPrefix}_username_${await DeviceSession.id}';
  Future<String> _genderKey() async =>
      '${_draftKeyPrefix}_gender_${await DeviceSession.id}';

  Future<void> _restoreDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final draftUsername = prefs.getString(await _usernameKey());
    final draftGender = prefs.getString(await _genderKey());
    if (!mounted) return;
    setState(() {
      if (draftUsername != null && draftUsername.isNotEmpty) {
        _usernameController.text = draftUsername;
        _usernameLength = draftUsername.length;
        _usernameError = _validateUsernameText(draftUsername);
      }
      if (draftGender != null && _genders.contains(draftGender)) {
        _selectedGender = draftGender;
      }
      _draftRestored = true;
    });
  }

  Future<void> _saveDraft() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(await _usernameKey(), _usernameController.text);
    if (_selectedGender != null) {
      await prefs.setString(await _genderKey(), _selectedGender!);
    }
  }

  Future<void> _clearDraft() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(await _usernameKey());
    await prefs.remove(await _genderKey());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _saveDraft(); // Fix #5: belt-and-suspenders save on backgrounding
    }
  }

  @override
  void dispose() {
    final deviceId = DeviceSession.idSync ?? 'anonymous';
    AnalyticsService.screenExit(
      screenName: 'profile_setup',
      uid: deviceId,
    );
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _usernameController.removeListener(_onUsernameChanged);
    _usernameController.dispose();
    super.dispose();
  }

  String? _validateUsernameText(String username) {
    if (username.isEmpty) return null;

    // Minimum length: 3 characters. Matches the server-side minimum in
    // auth_methods.dart's completeProfileSupabase / completeProfile — keep
    // both in sync, or a username can pass client-side and still fail on
    // submit (the same class of client/server drift this file's dot-regex
    // fix already addressed once).
    if (username.length < 3) {
      return "Username must be at least 3 characters";
    }

    if (username.length > 20) {
      return "Username must be 20 characters or fewer";
    }

    // Character-set is now enforced by _UsernameFormatter at input time, so
    // this check is just a safety net (e.g. for the restored draft).
    if (!RegExp(r'^[a-z0-9_.]+$').hasMatch(username)) {
      return "Only lowercase letters, numbers, . and _ allowed";
    }

    // REMOVED (per product decision): the previous startsWith/endsWith '.'
    // or '_' block. Usernames may now start or end with '.' or '_'.

    if (username.contains('..') ||
        username.contains('__') ||
        username.contains('._') ||
        username.contains('_.')) {
      return "Cannot have consecutive . or _ characters";
    }

    return null;
  }

  Future<void> completeProfile() async {
    setState(() => _submitAttempted = true); // Fix #3/#4

    final usernameError = _validateUsernameText(_usernameController.text);
    final missingGender = _selectedGender == null;
    final missingUsername =
        usernameError != null || _usernameController.text.trim().isEmpty;

    if (missingUsername || missingGender) {
      setState(() => _usernameError = usernameError);
      // Fix #3: one consolidated message naming everything that's missing,
      // rather than a single generic snackbar per attempt.
      final missing = <String>[];
      if (missingUsername) missing.add(usernameError ?? "a username");
      if (missingGender) missing.add("your gender");
      showSnackBar(context, "Please provide: ${missing.join(', ')}");
      return;
    }

    setState(() => _isLoading = true);

    final deviceId = DeviceSession.idSync ?? await DeviceSession.id;
    DebugLogger.logEvent(
        'PROFILE_SETUP_SUBMIT_STARTED', 'deviceId=$deviceId');

    final res = await AuthMethods().completeProfileSupabase(
      username: _usernameController.text.trim(),
      bio: "",
      file: null,
      dateOfBirth: widget.dateOfBirth,
      gender: _selectedGender!,
    );

    DebugLogger.logEvent(
        'PROFILE_SETUP_SUBMIT_RESULT', 'deviceId=$deviceId result=$res');

    if (res == "success") {
      await _clearDraft(); // Fix #5: don't resurrect a completed profile's draft
      widget.onComplete();

      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(
            builder: (context) => const ResponsiveLayout(
              mobileScreenLayout: MobileScreenLayout(),
            ),
          ),
          (route) => false,
        );
      }
    } else {
      if (mounted) showSnackBar(context, res);
    }

    if (mounted) setState(() => _isLoading = false);
  }

  bool get _isFormValid {
    return _validateUsernameText(_usernameController.text) == null &&
        _usernameController.text.trim().isNotEmpty &&
        _selectedGender != null;
  }

  @override
  Widget build(BuildContext context) {
    final showUsernameRequiredHint =
        _submitAttempted && _usernameController.text.trim().isEmpty;
    final showGenderRequiredHint = _submitAttempted && _selectedGender == null;

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: SingleChildScrollView(
            child: Column(
              children: [
                const SizedBox(height: 60),
                const Text(
                  'Profile Setup',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'Montserrat',
                    height: 1.3,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),

                // Username Section
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Fix #7: explicit "Required" signal up front, not just after
                    // a failed submit.
                    Row(
                      children: const [
                        Text(
                          'Create your username',
                          style: TextStyle(
                            color: Color(0xFFd9d9d9),
                            fontSize: 14,
                            fontFamily: 'Inter',
                          ),
                        ),
                        SizedBox(width: 6),
                        Text(
                          '(required)',
                          style: TextStyle(
                            color: Color(0xFF8a8a8a),
                            fontSize: 12,
                            fontFamily: 'Inter',
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextFieldInput(
                      hintText: 'username',
                      textInputType: TextInputType.text,
                      textEditingController: _usernameController,
                      fillColor: const Color(0xFF333333),
                      hintStyle: TextStyle(
                        color: Colors.grey[400],
                        fontFamily: 'Inter',
                      ),
                      // Fix #2: inputFormatters wired through to TextFieldInput.
                      // If TextFieldInput doesn't currently expose this param,
                      // add `List<TextInputFormatter>? inputFormatters` to its
                      // constructor and forward it to the underlying TextField.
                      inputFormatters: [_UsernameFormatter()],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Debounced: _usernameError is only set 800ms after
                          // the user stops typing (see _onUsernameChanged), so
                          // this text never flashes mid-keystroke.
                          if (_usernameError != null)
                            Expanded(
                              child: Semantics(
                                liveRegion: true, // Fix #6: screen readers announce it
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.error_outline,
                                        color: Colors.red, size: 14),
                                    const SizedBox(width: 4),
                                    Flexible(
                                      child: Text(
                                        _usernameError!,
                                        style: const TextStyle(
                                          color: Colors.red,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          else if (showUsernameRequiredHint)
                            Expanded(
                              child: Semantics(
                                liveRegion: true,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: const [
                                    Icon(Icons.error_outline,
                                        color: Colors.orangeAccent, size: 14),
                                    SizedBox(width: 4),
                                    Text(
                                      "Username is required",
                                      style: TextStyle(
                                        color: Colors.orangeAccent,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          else
                            const SizedBox.shrink(),
                          Text(
                            '$_usernameLength/20',
                            style: TextStyle(
                              color: _usernameLength > 20
                                  ? Colors.red
                                  : Colors.grey,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // Gender Section
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Fix #7
                    Row(
                      children: const [
                        Text(
                          'Select your gender',
                          style: TextStyle(
                            color: Color(0xFFd9d9d9),
                            fontSize: 14,
                            fontFamily: 'Inter',
                          ),
                        ),
                        SizedBox(width: 6),
                        Text(
                          '(required)',
                          style: TextStyle(
                            color: Color(0xFF8a8a8a),
                            fontSize: 12,
                            fontFamily: 'Inter',
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF333333),
                        borderRadius: BorderRadius.circular(12),
                        // Fix #4: same visual "needs attention" signal the
                        // username field gets, once the user has tried to submit.
                        border: showGenderRequiredHint
                            ? Border.all(color: Colors.orangeAccent, width: 1)
                            : null,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: DropdownButtonFormField<String>(
                          dropdownColor: const Color(0xFF333333),
                          value: _selectedGender,
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                          ),
                          items: _genders.map((String value) {
                            return DropdownMenuItem<String>(
                              value: value,
                              child: Text(
                                value,
                                style: const TextStyle(
                                  color: Color(0xFFd9d9d9),
                                  fontFamily: 'Inter',
                                ),
                              ),
                            );
                          }).toList(),
                          onChanged: (value) {
                            setState(() => _selectedGender = value);
                            _saveDraft(); // Fix #5
                          },
                          icon: const Icon(Icons.arrow_drop_down,
                              color: Color(0xFFd9d9d9)),
                          style: const TextStyle(
                            color: Color(0xFFd9d9d9),
                            fontFamily: 'Inter',
                          ),
                          hint: const Text(
                            'Choose gender',
                            style: TextStyle(
                              color: Color(0xFFd9d9d9),
                              fontFamily: 'Inter',
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Fix #4/#6: matching inline required-state text under the
                    // dropdown, same treatment as the username field.
                    if (showGenderRequiredHint)
                      Padding(
                        padding: const EdgeInsets.only(top: 4.0),
                        child: Semantics(
                          liveRegion: true,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(Icons.error_outline,
                                  color: Colors.orangeAccent, size: 14),
                              SizedBox(width: 4),
                              Text(
                                "Gender is required",
                                style: TextStyle(
                                  color: Colors.orangeAccent,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),

                const SizedBox(height: 40),
                // Fix #3: button stays tappable regardless of form state.
                // completeProfile() itself now surfaces exactly what's missing
                // instead of the button silently doing nothing.
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isFormValid
                        ? const Color(0xFF333333)
                        : const Color(0xFF2a2a2a),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    minimumSize: const Size(double.infinity, 50),
                  ),
                  onPressed: _isLoading ? null : completeProfile,
                  child: _isLoading
                      ? const CircularProgressIndicator(
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        )
                      : Text(
                          'Complete Profile',
                          style: TextStyle(
                            color:
                                _isFormValid ? Colors.white : Colors.grey[400],
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            fontFamily: 'Inter',
                          ),
                        ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
