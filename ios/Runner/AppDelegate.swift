import UIKit
import Flutter
import GoogleSignIn

@main
class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // This method handles all URL openings, including OAuth redirects
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey : Any] = [:]
  ) -> Bool {
    // First, try to let the Google Sign-In SDK handle the URL (if it's a Google sign-in redirect)
    if GIDSignIn.sharedInstance.handle(url) {
      print("✅ Google Sign-In handled URL: \(url.absoluteString)")
      return true
    }
    
    // Check if this is our custom scheme (ratedly://)
    // This is the Supabase OAuth redirect
    if url.scheme == "ratedly" {
      print("✅ Supabase OAuth redirect received: \(url.absoluteString)")
      
      // CRITICAL: Pass the URL to the Flutter engine
      // The supabase_flutter SDK will automatically handle this OAuth response
      return super.application(app, open: url, options: options)
    }
    
    // For any other URLs, use default handling
    return super.application(app, open: url, options: options)
  }
}
