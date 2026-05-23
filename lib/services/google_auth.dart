import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

class FirebaseServices {
  final auth = FirebaseAuth.instance;
  final GoogleSignIn googleSignIn = GoogleSignIn(scopes: ['email']);

  Future<bool> signInWithGoogle() async {
    try {
      // Start the sign-in process
      final GoogleSignInAccount? googleSignInAccount =
          await googleSignIn.signIn();

      if (googleSignInAccount == null) return false;

      // Get authentication tokens
      final GoogleSignInAuthentication googleAuth =
          await googleSignInAccount.authentication;

      // Create Firebase credential
      final AuthCredential authCredential = GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
        accessToken: googleAuth.accessToken,
      );

      await auth.signInWithCredential(authCredential);
      return true;
    } on FirebaseAuthException catch (e) {
      return false;
    } catch (e) {
      return false;
    }
  }

  Future<void> googleSignOut() async {
    await auth.signOut();
    await googleSignIn.signOut();
  }
}
