/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import os.log
import UIKit

open class FxAConfig {
    // FIXME: these should be lower case.
    // swiftlint:disable identifier_name
    public enum Server: String {
        case Release = "https://accounts.firefox.com"
        case Stable = "https://stable.dev.lcip.org"
        case Dev = "https://accounts.stage.mozaws.net"
    }

    // swiftlint:enable identifier_name

    let contentUrl: String
    let clientId: String
    let redirectUri: String

    public init(contentUrl: String, clientId: String, redirectUri: String) {
        self.contentUrl = contentUrl
        self.clientId = clientId
        self.redirectUri = redirectUri
    }

    public init(withServer server: Server, clientId: String, redirectUri: String) {
        contentUrl = server.rawValue
        self.clientId = clientId
        self.redirectUri = redirectUri
    }

    public static func release(clientId: String, redirectUri: String) -> FxAConfig {
        return FxAConfig(withServer: FxAConfig.Server.Release, clientId: clientId, redirectUri: redirectUri)
    }

    public static func stable(clientId: String, redirectUri: String) -> FxAConfig {
        return FxAConfig(withServer: FxAConfig.Server.Stable, clientId: clientId, redirectUri: redirectUri)
    }

    public static func dev(clientId: String, redirectUri: String) -> FxAConfig {
        return FxAConfig(withServer: FxAConfig.Server.Dev, clientId: clientId, redirectUri: redirectUri)
    }
}

public protocol PersistCallback {
    func persist(json: String)
}

// This queue serves as a semaphore to the rust layer.
private let rustQueue = DispatchQueue(label: "com.mozilla.firefox-account-rust")

open class FirefoxAccount {
    private let raw: UInt64
    private var persistCallback: PersistCallback?

    internal init(raw: UInt64) {
        self.raw = raw
    }

    /// Create a `FirefoxAccount` from scratch. This is suitable for callers using the
    /// OAuth Flow.
    /// Please note that the `FxAConfig` provided will be consumed and therefore
    /// should not be re-used.
    public convenience init(config: FxAConfig) throws {
        let pointer = try rustCall { err in
            fxa_new(config.contentUrl, config.clientId, config.redirectUri, err)
        }
        self.init(raw: pointer)
    }

    /// Restore a previous instance of `FirefoxAccount` from a serialized state (obtained with `toJSON(...)`).
    open class func fromJSON(state: String) throws -> FirefoxAccount {
        let pointer = try rustCall { err in fxa_from_json(state, err) }
        return FirefoxAccount(raw: pointer)
    }

    deinit {
        if self.raw != 0 {
            try! rustCall { err in
                // Is `try!` the right thing to do? We should only hit an error here
                // for panics and handle misuse, both inidicate bugs in our code
                // (the first in the rust code, the 2nd in this swift wrapper).
                fxa_free(self.raw, err)
            }
        }
    }

    /// Serializes the state of a `FirefoxAccount` instance. It can be restored
    /// later with `fromJSON(...)`. It is the responsability of the caller to
    /// persist that serialized state regularly (after operations that mutate
    /// `FirefoxAccount`) in a **secure** location.
    open func toJSON() throws -> String {
        let ptr = try rustCall { err in fxa_to_json(self.raw, err) }
        return String(freeingFxaString: ptr)
    }

    /// Registers a persistance callback. The callback will get called every time
    /// the `FirefoxAccount` state needs to be saved. The callback must
    /// persist the passed string in a secure location (like the keychain).
    public func registerPersistCallback(_ cb: PersistCallback) {
        persistCallback = cb
    }

    /// Unregisters a persistance callback.
    public func unregisterPersistCallback() {
        persistCallback = nil
    }

    private func tryPersistState() {
        DispatchQueue.global().async {
            guard let cb = self.persistCallback else {
                return
            }
            do {
                let json = try self.toJSON()
                DispatchQueue.global(qos: .background).async {
                    cb.persist(json: json)
                }
            } catch {
                // Ignore the error because the prior operation might have worked,
                // but still log it.
                os_log("FirefoxAccount internal state serialization failed.")
            }
        }
    }

    /// Gets the logged-in user profile.
    /// Throws `FirefoxAccountError.Unauthorized` if we couldn't find any suitable access token
    /// to make that call. The caller should then start the OAuth Flow again with
    /// the "profile" scope.
    open func getProfile(completionHandler: @escaping (Profile?, Error?) -> Void) {
        DispatchQueue.global().async {
            do {
                let profile = try self.getProfileSync()
                DispatchQueue.main.async { completionHandler(profile, nil) }
            } catch {
                DispatchQueue.main.async { completionHandler(nil, error) }
            }
        }
    }

    open func getProfileSync() throws -> Profile {
        let ptr = try rustCall { err in
            fxa_profile(self.raw, false, err)
        }
        defer { fxa_bytebuffer_free(ptr) }
        tryPersistState()
        let msg = try! MsgTypes_Profile(serializedData: Data(rustBuffer: ptr))
        return Profile(msg: msg)
    }

    open func getTokenServerEndpointURL() throws -> URL {
        let ptr = try rustCall { err in
            fxa_get_token_server_endpoint_url(self.raw, err)
        }
        return URL(string: String(freeingFxaString: ptr))!
    }

    open func getConnectionSuccessURL() throws -> URL {
        let ptr = try rustCall { err in
            fxa_get_connection_success_url(self.raw, err)
        }
        return URL(string: String(freeingFxaString: ptr))!
    }

    open func getManageAccountURL(entrypoint: String) throws -> URL {
        let ptr = try rustCall { err in
            fxa_get_manage_account_url(self.raw, entrypoint, err)
        }
        return URL(string: String(freeingFxaString: ptr))!
    }

    open func getManageDevicesURL(entrypoint: String) throws -> URL {
        let ptr = try rustCall { err in
            fxa_get_manage_devices_url(self.raw, entrypoint, err)
        }
        return URL(string: String(freeingFxaString: ptr))!
    }

    /// Request a OAuth token by starting a new OAuth flow.
    ///
    /// This function returns a URL string that the caller should open in a webview.
    ///
    /// Once the user has confirmed the authorization grant, they will get redirected to `redirect_url`:
    /// the caller must intercept that redirection, extract the `code` and `state` query parameters and call
    /// `completeOAuthFlow(...)` to complete the flow.
    open func beginOAuthFlow(scopes: [String], completionHandler: @escaping (URL?, Error?) -> Void) {
        DispatchQueue.global().async {
            do {
                let url = try self.beginOAuthFlowSync(scopes: scopes)
                DispatchQueue.main.async { completionHandler(url, nil) }
            } catch {
                DispatchQueue.main.async { completionHandler(nil, error) }
            }
        }
    }

    open func beginOAuthFlowSync(scopes: [String]) throws -> URL {
        let scope = scopes.joined(separator: " ")
        let ptr = try rustCall { err in
            fxa_begin_oauth_flow(self.raw, scope, err)
        }
        return URL(string: String(freeingFxaString: ptr))!
    }

    open func beginPairingFlowSync(pairingUrl: String, scopes: [String]) throws -> URL {
        let scope = scopes.joined(separator: " ")
        let ptr = try rustCall { err in
            fxa_begin_pairing_flow(self.raw, pairingUrl, scope, err)
        }
        return URL(string: String(freeingFxaString: ptr))!
    }

    /// Finish an OAuth flow initiated by `beginOAuthFlow(...)` and returns token/keys.
    ///
    /// This resulting token might not have all the `scopes` the caller have requested (e.g. the user
    /// might have denied some of them): it is the responsibility of the caller to accomodate that.
    open func completeOAuthFlow(code: String, state: String, completionHandler: @escaping (Void, Error?) -> Void) {
        DispatchQueue.global().async {
            do {
                try self.completeOAuthFlowSync(code: code, state: state)
                DispatchQueue.main.async { completionHandler((), nil) }
            } catch {
                DispatchQueue.main.async { completionHandler((), error) }
            }
        }
    }

    open func completeOAuthFlowSync(code: String, state: String) throws {
        try rustCall { err in
            fxa_complete_oauth_flow(self.raw, code, state, err)
        }
        tryPersistState()
    }

    /// Try to get an OAuth access token.
    ///
    /// Throws `FirefoxAccountError.Unauthorized` if we couldn't provide an access token
    /// for this scope. The caller should then start the OAuth Flow again with
    /// the desired scope.
    open func getAccessToken(scope: String, completionHandler: @escaping (AccessTokenInfo?, Error?) -> Void) {
        DispatchQueue.global().async {
            do {
                let tokenInfo = try self.getAccessTokenSync(scope: scope)
                DispatchQueue.main.async { completionHandler(tokenInfo, nil) }
            } catch {
                DispatchQueue.main.async { completionHandler(nil, error) }
            }
        }
    }

    open func getAccessTokenSync(scope: String) throws -> AccessTokenInfo {
        let ptr = try rustCall { err in
            fxa_get_access_token(self.raw, scope, err)
        }
        defer { fxa_bytebuffer_free(ptr) }
        tryPersistState()
        let msg = try! MsgTypes_AccessTokenInfo(serializedData: Data(rustBuffer: ptr))
        return AccessTokenInfo(msg: msg)
    }

    /// Check whether the refreshToken is active
    open func checkAuthorizationStatus(completionHandler: @escaping (IntrospectInfo?, Error?) -> Void) {
        DispatchQueue.global().async {
            do {
                let tokenInfo = try self.checkAuthorizationStatusSync()
                DispatchQueue.main.async { completionHandler(tokenInfo, nil) }
            } catch {
                DispatchQueue.main.async { completionHandler(nil, error) }
            }
        }
    }

    open func checkAuthorizationStatusSync() throws -> IntrospectInfo {
        let ptr = try rustCall { err in
            fxa_check_authorization_status(self.raw, err)
        }
        defer { fxa_bytebuffer_free(ptr) }
        let msg = try! MsgTypes_IntrospectInfo(serializedData: Data(rustBuffer: ptr))
        return IntrospectInfo(msg: msg)
    }

    /// This method should be called when a request made with
    /// an OAuth token failed with an authentication error.
    /// It clears the internal cache of OAuth access tokens,
    /// so the caller can try to call `getAccessToken` or `getProfile`
    /// again.
    open func clearAccessTokenCache(completionHandler: @escaping (Void, Error?) -> Void) {
        DispatchQueue.global().async {
            do {
                try self.clearAccessTokenCacheSync()
                DispatchQueue.main.async { completionHandler((), nil) }
            } catch {
                DispatchQueue.main.async { completionHandler((), error) }
            }
        }
    }

    open func clearAccessTokenCacheSync() throws {
        try rustCall { err in
            fxa_clear_access_token_cache(self.raw, err)
        }
    }

    /// Disconnect from the account and optionaly destroy our device record.
    /// `beginOAuthFlow(...)` will need to be called to reconnect.
    open func disconnect(completionHandler: @escaping (Void, Error?) -> Void) {
        DispatchQueue.global().async {
            do {
                try self.disconnectSync()
                DispatchQueue.main.async { completionHandler((), nil) }
            } catch {
                DispatchQueue.main.async { completionHandler((), error) }
            }
        }
    }

    open func disconnectSync() throws {
        try rustCall { err in
            fxa_disconnect(self.raw, err)
        }
        tryPersistState()
    }

    open func fetchDevicesSync() throws -> [Device] {
        let ptr = try rustCall { err in
            fxa_get_devices(self.raw, err)
        }
        defer { fxa_bytebuffer_free(ptr) }
        let msg = try! MsgTypes_Devices(serializedData: Data(rustBuffer: ptr))
        return Device.fromCollectionMsg(msg: msg)
    }

    open func setDeviceDisplayNameSync(_ name: String) throws {
        try rustCall { err in
            fxa_set_device_name(self.raw, name, err)
        }
    }

    open func pollDeviceCommandsSync() throws -> [DeviceEvent] {
        let ptr = try rustCall { err in
            fxa_poll_device_commands(self.raw, err)
        }
        defer { fxa_bytebuffer_free(ptr) }
        tryPersistState()
        let msg = try! MsgTypes_AccountEvents(serializedData: Data(rustBuffer: ptr))
        return DeviceEvent.fromCollectionMsg(msg: msg)
    }

    open func handlePushMessageSync(payload: String) throws -> [DeviceEvent] {
        let ptr = try rustCall { err in
            fxa_handle_push_message(self.raw, payload, err)
        }
        defer { fxa_bytebuffer_free(ptr) }
        tryPersistState()
        let msg = try! MsgTypes_AccountEvents(serializedData: Data(rustBuffer: ptr))
        return DeviceEvent.fromCollectionMsg(msg: msg)
    }

    open func sendSingleTabSync(targetId: String, title: String, url: String) throws {
        try rustCall { err in
            fxa_send_tab(self.raw, targetId, title, url, err)
        }
    }

    open func setDevicePushSubscriptionSync(endpoint: String, publicKey: String, authKey: String) throws {
        try rustCall { err in
            fxa_set_push_subscription(self.raw, endpoint, publicKey, authKey, err)
        }
    }

    open func initializeDeviceSync(name: String, deviceType: DeviceType, supportedCapabilities: [DeviceCapability]) throws {
        let (data, size) = capabilitiesToBuffer(capabilities: supportedCapabilities)
        try data.withUnsafeBytes { bytes in
            try rustCall { err in
                fxa_initialize_device(self.raw, name, Int32(deviceType.toMsg().rawValue), bytes, size, err)
            }
        }
    }

    open func ensureCapabilitiesSync(supportedCapabilities: [DeviceCapability]) throws {
        let (data, size) = capabilitiesToBuffer(capabilities: supportedCapabilities)
        try data.withUnsafeBytes { bytes in
            try rustCall { err in
                fxa_ensure_capabilities(self.raw, bytes, size, err)
            }
        }
    }

    internal func capabilitiesToBuffer(capabilities: [DeviceCapability]) -> (Data, Int32) {
        let msg = MsgTypes_Capabilities.with {
            $0.capability = capabilities.map { $0.toMsg() }
        }
        let data = try! msg.serializedData()
        let size = Int32(data.count)
        return (data, size)
    }
}

internal func rustCall<T>(_ cb: (UnsafeMutablePointer<FxAError>) throws -> T?) throws -> T {
    return try FirefoxAccountError.unwrap { err in
        try rustQueue.sync {
            try cb(err)
        }
    }
}

public struct ScopedKey {
    public let kty: String
    public let scope: String
    public let k: String
    public let kid: String

    internal init(msg: MsgTypes_ScopedKey) {
        kty = msg.kty
        scope = msg.scope
        k = msg.k
        kid = msg.kid
    }
}

public struct AccessTokenInfo {
    public let scope: String
    public let token: String
    public let key: ScopedKey?
    public let expiresAt: Date

    internal init(msg: MsgTypes_AccessTokenInfo) {
        scope = msg.scope
        token = msg.token
        key = msg.hasKey ? ScopedKey(msg: msg.key) : nil
        expiresAt = Date(timeIntervalSince1970: Double(msg.expiresAt))
    }
}

public struct IntrospectInfo {
    public let active: Bool
    public let tokenType: String
    public let scope: String?
    public let exp: Date
    public let iss: String?

    internal init(msg: MsgTypes_IntrospectInfo) {
        active = msg.active
        tokenType = msg.tokenType
        scope = msg.hasScope ? msg.scope : nil
        exp = Date(timeIntervalSince1970: Double(msg.exp))
        iss = msg.hasIss ? msg.iss : nil
    }
}

public struct Avatar {
    public let url: String
    public let isDefault: Bool
}

public struct Profile {
    public let uid: String
    public let email: String
    public let avatar: Avatar?
    public let displayName: String?

    internal init(msg: MsgTypes_Profile) {
        uid = msg.uid
        email = msg.email
        avatar = msg.hasAvatar ? Avatar(url: msg.avatar, isDefault: msg.avatarDefault) : nil
        displayName = msg.hasDisplayName ? msg.displayName : nil
    }
}
