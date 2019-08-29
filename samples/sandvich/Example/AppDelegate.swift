/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import MozillaAppServices

// NOTE: This is the client ID for "Android Components Reference Browser".
private let ClientID = "98adfa37698f255b"
private let RedirectURL = "https://lockbox.firefox.com/fxa/ios-redirect.html"

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    
    let redirectURL = RedirectURL
    
    // Probably shouldn't belong here but it's easy to share fxa between views.
    lazy var fxa: FxaAccountManager = {
        let config = FxAConfig.release(clientId: ClientID, redirectUri: RedirectURL)
        let deviceConfig = DeviceConfig(name: "Bobo Device", type: DeviceType.mobile, capabilities: [])
        let mgr = FxaAccountManager(config: config, deviceConfig: deviceConfig)
        // TODO: oh oh we haven't set an observer :/
        mgr.initialize { _ in
            // Technically wrong, we should wait on that closure or something
        }
        return mgr
    }()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        window = UIWindow(frame: UIScreen.main.bounds)
        let nav = UINavigationController(rootViewController: ViewController())
        window!.rootViewController = nav
        window!.makeKeyAndVisible()
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }


}

