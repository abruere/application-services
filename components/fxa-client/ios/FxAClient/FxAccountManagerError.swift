/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

public enum FxAccountManagerError: Error {
    // In the future we'll have 1 single error type, but for now we need to keep
    // backward compatibility...
    case internalFxaError(FirefoxAccountError)
    // Trying to finish an authentication that was never started with begin(...)Flow.
    case noExistingAuthFlow
    // Trying to finish a different authentication flow.
    case wrongAuthFlow
}
