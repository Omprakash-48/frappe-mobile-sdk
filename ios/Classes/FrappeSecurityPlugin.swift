import Flutter
import UIKit

public class FrappeSecurityPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "frappe_mobile_sdk/security",
            binaryMessenger: registrar.messenger()
        )
        let instance = FrappeSecurityPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "getMonotonicMillis" {
            result(Int64(ProcessInfo.processInfo.systemUptime * 1000))
        } else {
            result(FlutterMethodNotImplemented)
        }
    }
}
