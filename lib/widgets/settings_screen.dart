import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:Ratedly/resources/auth_methods.dart';
import 'package:Ratedly/resources/profile_firestore_methods.dart';
import 'package:Ratedly/screens/login.dart';
import 'package:Ratedly/screens/Profile_page/blocked_profile_screen.dart';
import 'package:Ratedly/resources/block_firestore_methods.dart';
import 'package:Ratedly/widgets/blue_verification_screen.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/screens/reactly_plus_screen.dart'; // ✅ ADDED

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isLoading = false;
  bool _isPrivate = false;
  final SupabaseClient _supabase = Supabase.instance.client;
  final AuthMethods _authMethods = AuthMethods();
  final GoogleSignIn _googleSignIn = GoogleSignIn(scopes: ['email']);
  String? _currentUserId;
  String? _currentUsername;
  String? _currentEmail;

  // GlobalKey to get the position of the Invite button for iOS share sheet anchor
  final GlobalKey _inviteButtonKey = GlobalKey();

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final userProvider = Provider.of<UserProvider>(context, listen: false);

    if (userProvider.firebaseUid != null && _currentUserId == null) {
      _currentUserId = userProvider.firebaseUid;
      _currentUsername = userProvider.user?.username;
      _currentEmail = userProvider.user?.email;
      _loadPrivacyStatus();
    } else if (userProvider.firebaseUid == null &&
        userProvider.supabaseUid != null &&
        _currentUserId == null) {
      _currentUserId = userProvider.supabaseUid;
      _currentUsername = userProvider.user?.username;
      _currentEmail = userProvider.user?.email;
      _loadPrivacyStatus();
    }
  }

  Future<void> _loadPrivacyStatus() async {
    if (_currentUserId == null) return;

    try {
      final response = await _supabase
          .from('users')
          .select('isPrivate, username, email')
          .eq('uid', _currentUserId!)
          .maybeSingle();

      if (response != null && mounted) {
        setState(() {
          _isPrivate = response['isPrivate'] ?? false;
          _currentUsername ??= response['username'] as String?;
          _currentEmail ??= response['email'] as String?;
        });
      } else if (mounted) {
        setState(() => _isPrivate = false);
      }
    } catch (e) {
      if (mounted) setState(() => _isPrivate = false);
    }
  }

  Future<void> _togglePrivacy(bool value) async {
    if (!mounted || _currentUserId == null) return;

    setState(() => _isLoading = true);

    try {
      await _supabase
          .from('users')
          .update({'isPrivate': value}).eq('uid', _currentUserId!);

      if (!value) {
        try {
          await SupabaseProfileMethods()
              .approveAllFollowRequests(_currentUserId!);
        } catch (e) {}
      }

      if (mounted) {
        setState(() => _isPrivate = value);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                value ? 'Account is now private' : 'Account is now public'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update privacy settings'),
            duration: Duration(seconds: 2),
          ),
        );
        setState(() => _isPrivate = !value);
      }
    }

    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _signOut() async {
    await _authMethods.signOut();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const LoginScreen()),
      );
    }
  }

  // =============================================
  // INVITE A FRIEND
  // =============================================
  Future<void> _inviteFriend() async {
    final username = _currentUsername ?? 'Someone';

    const iosLink = 'https://apps.apple.com/us/app/ratedly/id6746138563';
    const androidLink =
        'https://play.google.com/store/apps/details?id=com.ratedly.ratedly&hl=en';

    final message = '$username invited you to join Ratedly.\n\n'
        'iOS: $iosLink\n'
        'Android: $androidLink';

    await _logInviteShare(status: 'INVITE_TAPPED', platform: null);

    Rect shareOrigin = Rect.fromCenter(
      center: Offset(
        MediaQuery.of(context).size.width / 2,
        MediaQuery.of(context).size.height / 2,
      ),
      width: 1,
      height: 1,
    );
    final renderBox =
        _inviteButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox != null) {
      final position = renderBox.localToGlobal(Offset.zero);
      shareOrigin = position & renderBox.size;
    }

    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          text: message,
          subject: 'Join me on Ratedly!',
          sharePositionOrigin: shareOrigin,
        ),
      );

      if (result.status == ShareResultStatus.success) {
        await _logInviteShare(
          status: 'INVITE_SHARED',
          platform: result.raw.isNotEmpty ? result.raw : 'unknown',
        );
      } else if (result.status == ShareResultStatus.dismissed) {
        await _logInviteShare(status: 'INVITE_DISMISSED', platform: null);
      } else {
        await _logInviteShare(status: 'INVITE_UNAVAILABLE', platform: null);
      }
    } catch (e, stack) {
      await _logInviteShare(
        status: 'INVITE_ERROR',
        platform: null,
        errorDetails: e.toString(),
        stackTrace: stack.toString(),
      );
    }
  }

  Future<void> _logInviteShare({
    required String status,
    String? platform,
    String? errorDetails,
    String? stackTrace,
  }) async {
    try {
      await _supabase.from('invite_shares').insert({
        'user_id': _currentUserId ?? 'unknown',
        'username': _currentUsername,
        'status': status,
        'platform': platform,
        'error_details': errorDetails,
        'stack_trace': stackTrace,
      });
    } catch (e) {
      debugPrint('invite_shares log failed: $e');
    }
  }

  // =============================================
  // DELETION REASON DIALOG
  // Returns the selected reason + optional details,
  // or null if the user cancelled.
  // =============================================
  Future<Map<String, String?>?> _showDeletionReasonDialog(
      _ColorSet colors) async {
    String? selectedReason;
    final TextEditingController detailsController = TextEditingController();

    final reasons = [
      'Not enough users',
      'I did not receive ratings on my posts',
      'The feed (FYP) is boring',
      'I encountered an error',
      'Other',
    ];

    final result = await showDialog<Map<String, String?>>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final bool needsDetails =
                selectedReason == 'I encountered an error' ||
                    selectedReason == 'Other';
            final bool canConfirm = selectedReason != null &&
                (!needsDetails || detailsController.text.trim().isNotEmpty);

            return AlertDialog(
              backgroundColor: colors.cardColor,
              title: Text(
                'Before you go…',
                style: TextStyle(
                  color: colors.textColor,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'Montserrat',
                ),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Please tell us why you\'re leaving. Your feedback helps us improve.',
                      style: TextStyle(
                        color: colors.textColor.withOpacity(0.8),
                        fontSize: 14,
                        fontFamily: 'Inter',
                      ),
                    ),
                    const SizedBox(height: 16),
                    ...reasons.map((reason) {
                      return RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: reason,
                        groupValue: selectedReason,
                        activeColor: colors.textColor,
                        title: Text(
                          reason,
                          style: TextStyle(
                            color: colors.textColor,
                            fontSize: 14,
                            fontFamily: 'Inter',
                          ),
                        ),
                        onChanged: (value) {
                          setDialogState(() {
                            selectedReason = value;
                            detailsController.clear();
                          });
                        },
                      );
                    }).toList(),
                    if (needsDetails) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: detailsController,
                        maxLines: 3,
                        style: TextStyle(
                          color: colors.textColor,
                          fontFamily: 'Inter',
                          fontSize: 14,
                        ),
                        decoration: InputDecoration(
                          hintText: selectedReason == 'I encountered an error'
                              ? 'Describe the error…'
                              : 'Tell us more…',
                          hintStyle: TextStyle(
                            color: colors.textColor.withOpacity(0.45),
                            fontFamily: 'Inter',
                            fontSize: 14,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(
                                color: colors.textColor.withOpacity(0.3)),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderSide:
                                BorderSide(color: colors.textColor, width: 1.5),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                        ),
                        onChanged: (_) => setDialogState(() {}),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  child: Text(
                    'Cancel',
                    style:
                        TextStyle(color: colors.textColor, fontFamily: 'Inter'),
                  ),
                ),
                TextButton(
                  onPressed: canConfirm
                      ? () {
                          Navigator.of(context).pop({
                            'reason': selectedReason,
                            'details': needsDetails
                                ? detailsController.text.trim()
                                : null,
                          });
                        }
                      : null,
                  style: TextButton.styleFrom(
                    backgroundColor: canConfirm
                        ? Colors.red[900]
                        : Colors.red[900]!.withOpacity(0.3),
                  ),
                  child: Text(
                    'Delete Account',
                    style: TextStyle(
                      color: canConfirm ? Colors.red[100] : Colors.red[200],
                      fontFamily: 'Inter',
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    detailsController.dispose();
    return result;
  }

  // =============================================
  // LOG DELETION DATA TO SUPABASE
  // =============================================
  Future<void> _logDeletionData({
    required String uid,
    required String? username,
    required String? email,
    required String reason,
    String? details,
  }) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();

      // Insert into deleted_users
      await _supabase.from('deleted_users').insert({
        'uid': uid,
        'username': username,
        'email': email,
        'deleted_at': now,
      });
    } catch (e) {
      debugPrint('deleted_users insert failed: $e');
    }

    try {
      // Insert into deletion_reasons
      await _supabase.from('deletion_reasons').insert({
        'uid': uid,
        'reason': reason,
        'details': details,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      debugPrint('deletion_reasons insert failed: $e');
    }
  }

  // =============================================
  // DELETE ACCOUNT
  // =============================================
  Future<void> _deleteAccount() async {
    if (_currentUserId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('User not logged in')),
      );
      return;
    }

    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final colors = _getColors(themeProvider);

    // ── Step 1: First confirmation ──────────────────────────────────────────
    bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: colors.cardColor,
        title:
            Text('Delete Account', style: TextStyle(color: colors.textColor)),
        content: Text(
          'Are you sure you want to delete your account?',
          style: TextStyle(color: colors.textColor.withOpacity(0.9)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: colors.textColor)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(backgroundColor: Colors.red[900]),
            child: Text('Continue', style: TextStyle(color: Colors.red[100])),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    User? user = FirebaseAuth.instance.currentUser;
    final userId = _currentUserId!;
    final providers =
        user?.providerData.map((info) => info.providerId).toList() ?? [];
    final bool isAppleUser = providers.contains('apple.com');
    final bool isGoogleUser = providers.contains('google.com');
    final bool isSupabaseUser = user == null;

    // ── Step 2: Apple extra confirmation ────────────────────────────────────
    if (isAppleUser) {
      bool? finalConfirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: colors.cardColor,
          title: Text('Final Confirmation',
              style: TextStyle(color: colors.textColor)),
          content: Text(
            'This action cannot be undone. Your account and all data will be permanently deleted.',
            style: TextStyle(color: colors.textColor.withOpacity(0.9)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel', style: TextStyle(color: colors.textColor)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(backgroundColor: Colors.red[900]),
              child: Text('Delete Account',
                  style: TextStyle(color: Colors.red[100])),
            ),
          ],
        ),
      );

      if (finalConfirm != true || !mounted) return;
    }

    // ── Step 3: Deletion reason dialog ──────────────────────────────────────
    final reasonData = await _showDeletionReasonDialog(colors);
    if (reasonData == null || !mounted) return; // user cancelled

    setState(() => _isLoading = true);

    // ── Step 4: Re-authenticate if needed, then delete ──────────────────────
    try {
      AuthCredential? credential;

      if (!isSupabaseUser && !isAppleUser) {
        if (isGoogleUser) {
          try {
            final GoogleSignInAccount? googleUser =
                await _googleSignIn.signInSilently();
            if (googleUser == null) {
              final GoogleSignInAccount? googleUserInteractive =
                  await _googleSignIn.signIn();
              if (googleUserInteractive == null) {
                throw Exception('Google sign-in cancelled');
              }
              final GoogleSignInAuthentication googleAuth =
                  await googleUserInteractive.authentication;
              credential = GoogleAuthProvider.credential(
                idToken: googleAuth.idToken,
                accessToken: googleAuth.accessToken,
              );
            } else {
              final GoogleSignInAuthentication googleAuth =
                  await googleUser.authentication;
              credential = GoogleAuthProvider.credential(
                idToken: googleAuth.idToken,
                accessToken: googleAuth.accessToken,
              );
            }
            if (credential == null)
              throw Exception('Google credential not obtained');
            await user!.reauthenticateWithCredential(credential);
          } catch (e) {
            throw Exception('Google re-authentication failed: $e');
          }
        } else if (providers.contains('password')) {
          String? password = await showDialog<String>(
            context: context,
            builder: (_) {
              final controller = TextEditingController();
              return AlertDialog(
                backgroundColor: colors.cardColor,
                title: Text('Confirm Password',
                    style: TextStyle(color: colors.textColor)),
                content: TextField(
                  controller: controller,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    labelStyle:
                        TextStyle(color: colors.textColor.withOpacity(0.7)),
                  ),
                  style: TextStyle(color: colors.textColor),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(null),
                    child: Text('Cancel',
                        style: TextStyle(color: colors.textColor)),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(controller.text),
                    child: Text('Confirm',
                        style: TextStyle(color: colors.textColor)),
                  ),
                ],
              );
            },
          );

          if (password == null || password.isEmpty)
            throw Exception('Password required');
          credential = EmailAuthProvider.credential(
            email: user!.email!,
            password: password.trim(),
          );
          await user.reauthenticateWithCredential(credential);
        }
      }

      // ── Step 5: Log deletion data before proceeding ──────────────────────
      await _logDeletionData(
        uid: userId,
        username: _currentUsername,
        email: _currentEmail ??
            user?.email ??
            _supabase.auth.currentSession?.user.email,
        reason: reasonData['reason'] ?? 'Unknown',
        details: reasonData['details'],
      );

      // ── Step 6: Delete auth accounts (data is retained) ──────────────────
      try {
        String res = await SupabaseProfileMethods()
            .deleteEntireUserAccount(userId, credential);

        if (res == 'success') {
          _showSuccessAndNavigate();
        } else {
          throw Exception(res);
        }
      } catch (e, st) {
        if (isAppleUser) {
          _showSuccessAndNavigate();
        } else {
          rethrow;
        }
      }
    } on FirebaseAuthException catch (e) {
      if (isAppleUser && e.code == 'requires-recent-login') {
        _showSuccessAndNavigate();
      } else {
        String errorMessage = 'Account deletion failed';
        if (e.code == 'user-mismatch') {
          errorMessage = 'Authentication error: Please sign in again';
        } else if (e.code == 'requires-recent-login') {
          errorMessage = 'Session expired. Please sign in again';
        } else if (e.code == 'user-not-found') {
          errorMessage = 'User account not found';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorMessage)),
        );
      }
    } catch (e) {
      if (isAppleUser) {
        _showSuccessAndNavigate();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSuccessAndNavigate() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Account deleted successfully')),
    );
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  Future<void> _showFeedbackDialog() async {
    if (_currentUserId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('User not logged in')),
      );
      return;
    }

    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final colors = _getColors(themeProvider);

    final TextEditingController feedbackController = TextEditingController();
    bool isSending = false;

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: colors.cardColor,
              title: Text('Share Your Feedback',
                  style: TextStyle(color: colors.textColor)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'We care about your experience! Share suggestions for new features or improvements to help us make Ratedly better.',
                    style: TextStyle(
                        color: colors.textColor.withOpacity(0.8), fontSize: 14),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: feedbackController,
                    maxLines: 5,
                    style: TextStyle(color: colors.textColor),
                    decoration: InputDecoration(
                      hintText: 'Type your feedback here...',
                      hintStyle:
                          TextStyle(color: colors.textColor.withOpacity(0.5)),
                      border: OutlineInputBorder(
                        borderSide: BorderSide(
                            color: colors.textColor.withOpacity(0.3)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(
                            color: colors.textColor.withOpacity(0.3)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: colors.textColor),
                      ),
                    ),
                  ),
                  if (isSending) const SizedBox(height: 16),
                  if (isSending)
                    Center(
                        child:
                            CircularProgressIndicator(color: colors.textColor)),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child:
                      Text('Cancel', style: TextStyle(color: colors.textColor)),
                ),
                TextButton(
                  onPressed: isSending
                      ? null
                      : () async {
                          final feedbackText = feedbackController.text.trim();
                          if (feedbackText.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text('Please enter your feedback',
                                      style: TextStyle(color: Colors.white))),
                            );
                            return;
                          }

                          setState(() => isSending = true);
                          try {
                            final userId = _currentUserId!;
                            await FirebaseFirestore.instance
                                .collection('feedback')
                                .add({
                              'userId': userId,
                              'feedback': feedbackText,
                              'timestamp': FieldValue.serverTimestamp(),
                            });

                            if (mounted) {
                              Navigator.of(context).pop();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text(
                                        'Thank you for your feedback!',
                                        style: TextStyle(color: Colors.white))),
                              );
                            }
                          } catch (e) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text(
                                        'Failed to send feedback: ${e.toString()}',
                                        style: TextStyle(color: Colors.white))),
                              );
                            }
                          } finally {
                            if (mounted) setState(() => isSending = false);
                          }
                        },
                  style: TextButton.styleFrom(
                    backgroundColor: colors.backgroundColor,
                  ),
                  child: Text(
                    'Send Feedback',
                    style: TextStyle(color: colors.textColor),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildOptionTile({
    required String title,
    required IconData icon,
    VoidCallback? onTap,
    Color? iconColor,
    Widget? trailing,
    Key? tileKey,
  }) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);

    return Container(
      key: tileKey,
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: colors.cardColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        leading: Icon(icon, color: iconColor ?? colors.iconColor),
        title: Text(title, style: TextStyle(color: colors.textColor)),
        trailing: trailing,
        onTap: onTap,
        enabled: onTap != null,
      ),
    );
  }

  _ColorSet _getColors(ThemeProvider themeProvider) {
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;
    return isDarkMode ? _DarkColors() : _LightColors();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;

    if (_currentUserId == null) {
      final userProvider = Provider.of<UserProvider>(context, listen: false);
      if (userProvider.firebaseUid != null) {
        _currentUserId = userProvider.firebaseUid;
        _currentUsername = userProvider.user?.username;
        _currentEmail = userProvider.user?.email;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadPrivacyStatus();
        });
      } else if (userProvider.supabaseUid != null) {
        _currentUserId = userProvider.supabaseUid;
        _currentUsername = userProvider.user?.username;
        _currentEmail = userProvider.user?.email;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadPrivacyStatus();
        });
      }
    }

    // ✅ Determine if we should show Reactly+ (only on iOS / iPhone)
    final bool showReactlyPlus =
        Theme.of(context).platform == TargetPlatform.iOS;

    return Scaffold(
      backgroundColor: colors.backgroundColor,
      appBar: AppBar(
        title: Text('Settings', style: TextStyle(color: colors.textColor)),
        centerTitle: true,
        backgroundColor: colors.backgroundColor,
        elevation: 1,
        iconTheme: IconThemeData(color: colors.textColor),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: colors.textColor))
          : SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    // ✅ Conditionally show Reactly+ button (only on iOS)
                    if (showReactlyPlus)
                      _buildOptionTile(
                        title: 'Reactly+',
                        icon: Icons.star,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const ReactlyPlusScreen()),
                        ),
                      ),
                    // Blue Verification button removed
                    _buildOptionTile(
                      title: 'Invite a Friend',
                      icon: Icons.person_add_alt_1,
                      onTap: _inviteFriend,
                      tileKey: _inviteButtonKey,
                    ),
                    _buildOptionTile(
                      title: 'Dark Mode',
                      icon: Icons.dark_mode,
                      onTap: () {},
                      trailing: Switch(
                        value: isDarkMode,
                        onChanged: (value) => themeProvider.toggleTheme(value),
                      ),
                    ),
                    _buildOptionTile(
                      title: 'Send Feedback',
                      icon: Icons.feedback,
                      onTap: _showFeedbackDialog,
                    ),
                    _buildOptionTile(
                      title: 'Private Account',
                      icon: Icons.lock,
                      onTap: () {},
                      trailing: Switch(
                        value: _isPrivate,
                        onChanged:
                            _currentUserId != null ? _togglePrivacy : null,
                        activeColor: colors.textColor,
                      ),
                    ),
                    _buildOptionTile(
                      title: 'Blocked Users',
                      icon: Icons.block,
                      onTap: _currentUserId != null
                          ? () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => BlockedUsersList(
                                    uid: _currentUserId!,
                                  ),
                                ),
                              )
                          : null,
                    ),
                    _buildOptionTile(
                      title: 'Sign Out',
                      icon: Icons.logout,
                      onTap: _signOut,
                    ),
                    _buildOptionTile(
                      title: 'Delete Account',
                      icon: Icons.delete,
                      iconColor: Colors.red[400],
                      onTap: _deleteAccount,
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _ColorSet {
  final Color textColor;
  final Color backgroundColor;
  final Color cardColor;
  final Color iconColor;

  _ColorSet({
    required this.textColor,
    required this.backgroundColor,
    required this.cardColor,
    required this.iconColor,
  });
}

class _DarkColors extends _ColorSet {
  _DarkColors()
      : super(
          textColor: const Color(0xFFd9d9d9),
          backgroundColor: const Color(0xFF121212),
          cardColor: const Color(0xFF333333),
          iconColor: const Color(0xFFd9d9d9),
        );
}

class _LightColors extends _ColorSet {
  _LightColors()
      : super(
          textColor: Colors.black,
          backgroundColor: Colors.grey[100]!,
          cardColor: Colors.white,
          iconColor: Colors.grey[700]!,
        );
}

class BlockedUsersList extends StatefulWidget {
  final String uid;
  const BlockedUsersList({Key? key, required this.uid}) : super(key: key);

  @override
  State<BlockedUsersList> createState() => _BlockedUsersListState();
}

class _BlockedUsersListState extends State<BlockedUsersList> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final SupabaseBlockMethods _blockMethods = SupabaseBlockMethods();

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;
    final colors = isDarkMode ? _DarkColors() : _LightColors();

    return Scaffold(
      backgroundColor: colors.backgroundColor,
      appBar: AppBar(
        title: Text('Blocked Users', style: TextStyle(color: colors.textColor)),
        backgroundColor: colors.backgroundColor,
        iconTheme: IconThemeData(color: colors.textColor),
      ),
      body: FutureBuilder<List<String>>(
        future: _blockMethods.getBlockedUsers(widget.uid),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(
                child: CircularProgressIndicator(color: colors.textColor));
          }

          if (snapshot.hasError) {
            return Center(
              child: Text('Error loading blocked users',
                  style: TextStyle(color: colors.textColor)),
            );
          }

          final blockedUserIds = snapshot.data ?? [];

          if (blockedUserIds.isEmpty) {
            return Center(
              child: Text('No blocked users',
                  style: TextStyle(color: colors.textColor)),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: blockedUserIds.length,
            separatorBuilder: (context, index) =>
                Divider(color: colors.cardColor, height: 20),
            itemBuilder: (context, index) {
              final blockedUserId = blockedUserIds[index];
              return FutureBuilder<Map<String, dynamic>>(
                future: _getUserDetails(blockedUserId),
                builder: (context, userSnapshot) {
                  if (userSnapshot.connectionState == ConnectionState.waiting) {
                    return ListTile(
                      leading: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: colors.cardColor,
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: CircularProgressIndicator(
                            color: colors.textColor,
                            strokeWidth: 2,
                          ),
                        ),
                      ),
                      title: Text('Loading...',
                          style: TextStyle(color: colors.textColor)),
                    );
                  }

                  if (userSnapshot.hasError || !userSnapshot.hasData) {
                    return ListTile(
                      leading: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: colors.cardColor,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.error, color: colors.textColor),
                      ),
                      title: Text('Unknown User',
                          style: TextStyle(color: colors.textColor)),
                      subtitle: Text(blockedUserId,
                          style: TextStyle(
                              color: colors.textColor.withOpacity(0.6))),
                    );
                  }

                  final userData = userSnapshot.data!;
                  final username = userData['username'] ?? 'Unknown User';
                  final photoUrl = userData['photoUrl'] ?? '';

                  return ListTile(
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: colors.cardColor,
                        shape: BoxShape.circle,
                      ),
                      child: (photoUrl.isNotEmpty && photoUrl != "default")
                          ? ClipOval(
                              child: Image.network(
                                photoUrl,
                                width: 44,
                                height: 44,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  return Icon(Icons.person,
                                      color: colors.textColor, size: 24);
                                },
                                loadingBuilder:
                                    (context, child, loadingProgress) {
                                  if (loadingProgress == null) return child;
                                  return Center(
                                    child: CircularProgressIndicator(
                                      value:
                                          loadingProgress.expectedTotalBytes !=
                                                  null
                                              ? loadingProgress
                                                      .cumulativeBytesLoaded /
                                                  loadingProgress
                                                      .expectedTotalBytes!
                                              : null,
                                      color: colors.textColor,
                                    ),
                                  );
                                },
                              ),
                            )
                          : Center(
                              child: Icon(Icons.person,
                                  color: colors.textColor, size: 24),
                            ),
                    ),
                    title: Text(
                      username,
                      style: TextStyle(
                        color: colors.textColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    trailing: IconButton(
                      icon: Icon(Icons.lock_open, color: colors.textColor),
                      onPressed: () => _unblockUser(blockedUserId),
                    ),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => BlockedProfileScreen(
                            uid: blockedUserId,
                            isBlocker: true,
                          ),
                        ),
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Future<Map<String, dynamic>> _getUserDetails(String userId) async {
    try {
      final response = await _supabase
          .from('users')
          .select('username, photoUrl')
          .eq('uid', userId)
          .single();
      return response;
    } catch (e) {
      return {};
    }
  }

  Future<void> _unblockUser(String targetUserId) async {
    try {
      await _blockMethods.unblockUser(
        currentUserId: widget.uid,
        targetUserId: targetUserId,
      );
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('User unblocked successfully')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to unblock user: ${e.toString()}')),
      );
    }
  }
}
