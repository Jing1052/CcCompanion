//
//  AppDelegate.swift
//  CcCompanion
//
//  Handles standard remote notification lifecycle:
//  - didRegisterForRemoteNotificationsWithDeviceToken → PushTokenManager uploads hex token
//  - didFailToRegisterForRemoteNotifications → log only
//  - didReceiveRemoteNotification (content-available silent push) → no-op for now
//  - UNUserNotificationCenterDelegate.willPresent → show banner even in foreground
//

import UIKit
import UserNotifications

extension Notification.Name {
    // Phase 3 (thinking-stream-render): silent push 带 turn_id 到达 → 通知 ChatViewModel 拉 thinking.
    static let ccThinkingPending = Notification.Name("CcThinkingPending")
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        Task {
            await PushTokenManager.shared.registerDeviceToken(deviceToken)
        }
        #endif
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[PushToken] didFailToRegisterForRemoteNotifications: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Phase 3 (thinking-stream-render, build 223): server POST /v1/thinking 后发 content-available
        // silent push, payload 带 turn_id. 解出来广播给 ChatViewModel 直接按 turn_id 拉 thinking,
        // 不依赖新 chat record (修空 fetch 竞态的第三条路). 解不出 turn_id 静默, 不弹 alert.
        if let tid = userInfo["turn_id"] as? String, !tid.isEmpty {
            NotificationCenter.default.post(name: .ccThinkingPending, object: nil, userInfo: ["turn_id": tid])
        }
        completionHandler(.newData)
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.identifier.hasPrefix(ChatViewModel.pollingAssistantNotificationIdentifierPrefix) {
            completionHandler([.banner, .list, .sound, .badge])
            return
        }
        // build 93: 应用前台不弹 banner / 不响声 静默进通知中心 (badge 仍更新)
        completionHandler([.list, .badge])
    }
}
