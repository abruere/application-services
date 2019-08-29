/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import os

public protocol DeviceConstellationProtocol {
    // Get local + remote devices.
    func state() -> ConstellationState?
    // Refresh the list of remote devices.
    // Dispatchs a notification to NSNotificationCenter, using the name `.constellationStateUpdate`.
    // The updated `ConstellationState` can be found in `userInfo` under the key `newState`.
    func refreshState()

    func setLocalDeviceName(name: String)

    // Poll for events we might have missed (e.g. no push notification)
    func pollForEvents(completionHandler: @escaping (Result<[DeviceEvent], FxAccountManagerError>) -> Void)
    // Send an event to another device such as Send Tab.
    func sendEventToDevice(targetDeviceId: String, e: DeviceEventOutgoing)

    // Register our push subscription with the FxA server.
    func setDevicePushSubscription(sub: DevicePushSubscription)
    // Used by Push when receiving a message.
    func processRawIncomingDeviceEvent(pushPayload: String, completionHandler: @escaping (Result<[DeviceEvent], FxAccountManagerError>) -> Void)
}

public extension Notification.Name {
    static let constellationStateUpdate = Notification.Name("constellationStateUpdate")
}

public struct ConstellationState {
    public let localDevice: Device?
    public let remoteDevices: [Device]
}

public class DeviceConstellation: DeviceConstellationProtocol {
    var constellationState: ConstellationState?
    let account: FirefoxAccount

    required init(account: FirefoxAccount) {
        self.account = account
    }

    public func state() -> ConstellationState? {
        return constellationState
    }

    public func refreshState() {
        fxaQueue.async {
            os_log("Refreshing device list...")
            do {
                let devices = try self.account.fetchDevicesSync()
                let localDevice = devices.first { $0.isCurrentDevice }
                if localDevice?.subscriptionExpired ?? false {
                    os_log("Current device needs push endpoint registration.")
                }
                let remoteDevices = devices.filter { !$0.isCurrentDevice }

                let newState = ConstellationState(localDevice: localDevice, remoteDevices: remoteDevices)
                self.constellationState = newState

                log("Refreshed device list; saw \(devices.count) device(s).")

                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .constellationStateUpdate,
                        object: nil,
                        userInfo: ["newState": newState]
                    )
                }
            } catch {
                log("Failure fetching the device list: \(error).")
                return
            }
        }
    }

    func initDevice(name: String, type: DeviceType, capabilities: [DeviceCapability]) {
        // This is already wrapped in a `fxaQueue.async`, no need to re-wrap.
        do {
            try account.initializeDeviceSync(name: name, deviceType: type, supportedCapabilities: capabilities)
        } catch {
            log("Failure initializing device: \(error).")
        }
    }

    func ensureCapabilities(capabilities: [DeviceCapability]) {
        // This is already wrapped in a `fxaQueue.async`, no need to re-wrap.
        do {
            try account.ensureCapabilitiesSync(supportedCapabilities: capabilities)
        } catch {
            log("Failure ensuring device capabilities: \(error).")
        }
    }

    public func setLocalDeviceName(name: String) {
        fxaQueue.async {
            do {
                try self.account.setDeviceDisplayNameSync(name)
            } catch {
                log("Failure changing the local device name: \(error).")
            }
            self.refreshState()
        }
    }

    public func pollForEvents(completionHandler: @escaping (Result<[DeviceEvent], FxAccountManagerError>) -> Void) {
        fxaQueue.async {
            do {
                let events = try self.account.pollDeviceCommandsSync()
                DispatchQueue.main.async { completionHandler(.success(events)) }
            } catch {
                DispatchQueue.main.async {
                    completionHandler(.failure(FxAccountManagerError.internalFxaError(error as! FirefoxAccountError)))
                }
            }
        }
    }

    public func sendEventToDevice(targetDeviceId: String, e: DeviceEventOutgoing) {
        fxaQueue.async {
            do {
                switch e {
                case let .sendTab(title, url): do {
                    try self.account.sendSingleTabSync(targetId: targetDeviceId, title: title, url: url)
                }
                }
            } catch {
                log("Error sending event to another device: \(error).")
            }
        }
    }

    public func setDevicePushSubscription(sub: DevicePushSubscription) {
        // No need to wrap in async, this operation doesn't do any IO or heavy processing.
        do {
            try account.setDevicePushSubscriptionSync(endpoint: sub.endpoint, publicKey: sub.publicKey, authKey: sub.authKey)
        } catch {
            log("Failure setting push subscription: \(error).")
        }
    }

    public func processRawIncomingDeviceEvent(pushPayload: String,
                                              completionHandler: @escaping (Result<[DeviceEvent], FxAccountManagerError>) -> Void) {
        fxaQueue.async {
            do {
                let events = try self.account.handlePushMessageSync(payload: pushPayload)
                DispatchQueue.main.async { completionHandler(.success(events)) }
            } catch {
                DispatchQueue.main.async {
                    completionHandler(.failure(FxAccountManagerError.internalFxaError(error as! FirefoxAccountError)))
                }
            }
        }
    }
}

public enum DeviceEventOutgoing {
    case sendTab(title: String, url: String)
}
