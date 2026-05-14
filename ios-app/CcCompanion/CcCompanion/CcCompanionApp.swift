//
//  CcCompanionApp.swift
//  CcCompanion
//
//  Created by HoshimiMian on 2026/4/28.
//

import SwiftUI
import UIKit
import CoreText

@main
struct CcCompanionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Phase multi-server fallback (2026-05-11) — 旧版单 serverURL 一次性迁到新 endpoints 列表.
        CcServerConfig.migrateLegacySingleURLIfNeeded()
        CcServerConfig.syncToAppGroup()
        Self.registerCustomFonts()
    }

    private static func registerCustomFonts() {
        let names = [
            "SourceSerif4-Regular",
            "SourceSerif4-Semibold",
            "SourceHanSerifSC-Regular",
            "SourceHanSerifSC-Bold",
        ]
        for n in names {
            guard let url = Bundle.main.url(forResource: n, withExtension: "otf") else {
                print("[CcFont] missing in bundle: \(n).otf")
                continue
            }
            var err: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err) {
                print("[CcFont] register failed \(n): \(err.debugDescription)")
            }
        }
        let han = UIFont.fontNames(forFamilyName: "Source Han Serif SC")
        let serif = UIFont.fontNames(forFamilyName: "Source Serif 4")
        print("[CcFont] Source Han Serif SC fonts = \(han)")
        print("[CcFont] Source Serif 4 fonts = \(serif)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .ccSerifTheme()
        }
        #if targetEnvironment(macCatalyst)
        .commands {
            CommandGroup(replacing: .pasteboard) {
                Button("Paste") {
                    NotificationCenter.default.post(name: .ccPasteFromClipboard, object: nil)
                }
                .keyboardShortcut("v", modifiers: .command)
            }
        }
        #endif
    }
}

extension Notification.Name {
    static let ccPasteFromClipboard = Notification.Name("ccPasteFromClipboard")
}
