/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import os.log
import SwiftKeychainWrapper

class KeyChainAccountStorage: AccountStorage {
    internal var keychainWrapper: KeychainWrapper
    internal static var keychainKey: String = "accountJSON"

    init(keychainAccessGroup: String?) {
        keychainWrapper = KeychainWrapper.sharedAppContainerKeychain(keychainAccessGroup: keychainAccessGroup)
    }

    func read() -> FirefoxAccount? {
        if let json = keychainWrapper.string(forKey: KeyChainAccountStorage.keychainKey) {
            do {
                return try FirefoxAccount.fromJSON(state: json)
            } catch {
                os_log("FirefoxAccount internal state de-serialization failed.")
                return nil
            }
        }
        return nil
    }

    func write(_ json: String) {
        if !keychainWrapper.set(json, forKey: KeyChainAccountStorage.keychainKey) {
            os_log("Could not write account state.")
        }
    }

    func clear() {
        if !keychainWrapper.removeObject(forKey: KeyChainAccountStorage.keychainKey) {
            os_log("Could not clear account state.")
        }
    }
}
