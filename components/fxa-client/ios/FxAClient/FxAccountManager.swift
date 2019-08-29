/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import os.log

let fxaQueue = DispatchQueue(label: "com.mozilla.fxa-mgr")

// TODO: doc for each public func in protocols.
protocol FxaAccountManagerProtocol {
    init(config: FxAConfig, deviceConfig: DeviceConfig, applicationScopes: [String], keychainAccessGroup: String?)

    // Starts the FxA account manager and advances the state machine.
    // It is required to call this method before doing anything else with the manager.
    func initialize(completionHandler: @escaping (Result<Void, FxAccountManagerError>) -> Void)

    func hasAccount() -> Bool
    func accountProfile() -> Profile?
    func refreshProfile()
    func accountNeedsReauth() -> Bool

    func beginAuthentication(completionHandler: @escaping (Result<URL, FxAccountManagerError>) -> Void)
    func beginPairingAuthentication(pairingUrl: String, completionHandler: @escaping (Result<URL, FxAccountManagerError>) -> Void)
    func finishAuthentication(authData: FxaAuthData, completionHandler: @escaping (Result<Void, FxAccountManagerError>) -> Void)
    func getAccessToken(scope: String, completionHandler: @escaping (Result<AccessTokenInfo, FxAccountManagerError>) -> Void)

    func deviceConstellation() -> DeviceConstellationProtocol?

    func logout(completionHandler: @escaping (Result<Void, FxAccountManagerError>) -> Void)
}

public extension Notification.Name {
    static let accountLoggedOut = Notification.Name("accountLoggedOut")
    static let accountAuthProblems = Notification.Name("accountAuthProblems")
    static let accountAuthenticated = Notification.Name("accountAuthenticated")
    static let accountProfileUpdate = Notification.Name("accountProfileUpdate")
}

protocol AccountStorage {
    func read() -> FirefoxAccount?
    func write(_ json: String)
    func clear()
}

open class FxaAccountManager: FxaAccountManagerProtocol {
    var acct: FirefoxAccount?
    var account: FirefoxAccount? {
        get { return acct }
        set {
            acct = newValue
            if let acc = acct {
                constellation = DeviceConstellation(account: acc)
            }
        }
    }

    let config: FxAConfig
    let deviceConfig: DeviceConfig
    let applicationScopes: [String]
    var state: AccountState = AccountState.start
    var profile: Profile?
    var constellation: DeviceConstellation?
    var latestAuthState: String?

    public required init(
        config: FxAConfig,
        deviceConfig: DeviceConfig,
        applicationScopes: [String] = [Scope.profile, Scope.sync],
        keychainAccessGroup: String? = nil
    ) {
        self.config = config
        self.deviceConfig = deviceConfig
        self.applicationScopes = applicationScopes
        accountStorage = KeyChainAccountStorage(keychainAccessGroup: keychainAccessGroup)
    }

    let accountStorage: AccountStorage

    lazy var statePersistenceCallback: FxAStatePersistenceCallback = {
        FxAStatePersistenceCallback(manager: self)
    }()

    public func initialize(completionHandler: @escaping (Result<Void, FxAccountManagerError>) -> Void) {
        fxaQueue.async {
            self.processQueue(event: .initialize)
            DispatchQueue.main.async { completionHandler(Result.success(())) }
        }
    }

    public func hasAccount() -> Bool {
        return state == .authenticatedWithProfile ||
            state == .authenticatedNoProfile ||
            state == .authenticationProblem
    }

    public func accountNeedsReauth() -> Bool {
        return state == .authenticationProblem
    }

    public func beginAuthentication(completionHandler: @escaping (Result<URL, FxAccountManagerError>) -> Void) {
        fxaQueue.async {
            let result = self.updatingLatestAuthState {
                try self.requireAccount().beginOAuthFlowSync(scopes: self.applicationScopes)
            }
            DispatchQueue.main.async { completionHandler(result) }
        }
    }

    public func beginPairingAuthentication(pairingUrl: String, completionHandler: @escaping (Result<URL, FxAccountManagerError>) -> Void) {
        fxaQueue.async {
            let result = self.updatingLatestAuthState {
                try self.requireAccount().beginPairingFlowSync(pairingUrl: pairingUrl, scopes: self.applicationScopes)
            }
            DispatchQueue.main.async { completionHandler(result) }
        }
    }

    private func updatingLatestAuthState(_ beginFlowFn: () throws -> URL) -> Result<URL, FxAccountManagerError> {
        do {
            let url = try beginFlowFn()
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: true)
            latestAuthState = comps!.queryItems!.first(where: { $0.name == "state" })!.value
            return .success(url)
        } catch {
            return .failure(FxAccountManagerError.internalFxaError(error as! FirefoxAccountError))
        }
    }

    public func finishAuthentication(authData: FxaAuthData, completionHandler: @escaping (Result<Void, FxAccountManagerError>) -> Void) {
        fxaQueue.async {
            let result: Result<Void, FxAccountManagerError>
            if self.latestAuthState == nil {
                result = .failure(FxAccountManagerError.noExistingAuthFlow)
            } else if authData.state != self.latestAuthState {
                result = .failure(FxAccountManagerError.wrongAuthFlow)
            } else { /* state == latestAuthState */
                self.processQueue(event: .authenticated(authData: authData))
                result = .success(())
            }
            DispatchQueue.main.async { completionHandler(result) }
        }
    }

    public func getAccessToken(scope: String, completionHandler: @escaping (Result<AccessTokenInfo, FxAccountManagerError>) -> Void) {
        fxaQueue.async {
            do {
                let token = try self.requireAccount().getAccessTokenSync(scope: scope)
                DispatchQueue.main.async { completionHandler(.success(token)) }
            } catch {
                DispatchQueue.main.async {
                    completionHandler(.failure(FxAccountManagerError.internalFxaError(error as! FirefoxAccountError)))
                }
            }
        }
    }

    public func refreshProfile() {
        fxaQueue.async {
            self.processQueue(event: .fetchProfile)
        }
    }

    public func accountProfile() -> Profile? {
        if state == .authenticatedWithProfile || state == .authenticationProblem {
            return profile
        }
        return nil
    }

    public func deviceConstellation() -> DeviceConstellationProtocol? {
        return constellation
    }

    public func logout(completionHandler: @escaping (Result<Void, FxAccountManagerError>) -> Void) {
        fxaQueue.async {
            self.processQueue(event: .logout)
            DispatchQueue.main.async { completionHandler(.success(())) }
        }
    }

    internal func processQueue(event: Event) {
        var toProcess: Event? = event
        while let e = toProcess {
            guard let nextState = FxaAccountManager.nextState(state: self.state, event: e) else {
                log("Got invalid event \(e) for state \(state).")
                continue
            }
            log("Processing event \(e) for state \(state). Next state is \(nextState).")
            state = nextState
            toProcess = stateActions(forState: state, via: e)
            if let successiveEvent = toProcess {
                log("Ran \(e) side-effects for state \(state), got successive event \(successiveEvent).")
            }
        }
    }

    // State transition matrix. Returns nil if there's no transition.
    internal static func nextState(state: AccountState, event: Event) -> AccountState? {
        switch state {
        case .start:
            switch event {
            case .initialize: return .start
            case .accountNotFound: return .notAuthenticated
            case .accountRestored: return .authenticatedNoProfile
            default: return nil
            }
        case .notAuthenticated:
            switch event {
            case .authenticated: return .authenticatedNoProfile
            default: return nil
            }
        case .authenticatedNoProfile:
            switch event {
            case .authenticationError: return .authenticationProblem
            case .fetchProfile: return .authenticatedNoProfile
            case .fetchedProfile: return .authenticatedWithProfile
            case .failedToFetchProfile: return .authenticatedNoProfile
            case .logout: return .notAuthenticated
            default: return nil
            }
        case .authenticatedWithProfile:
            switch event {
            case .authenticationError: return .authenticationProblem
            case .logout: return .notAuthenticated
            default: return nil
            }
        case .authenticationProblem:
            switch event {
            case .recoveredFromAuthenticationProblem: return .authenticatedNoProfile
            case .authenticated: return .authenticatedNoProfile
            case .logout: return .notAuthenticated
            default: return nil
            }
        }
    }

    // swiftlint:disable function_body_length
    internal func stateActions(forState: AccountState, via: Event) -> Event? {
        switch forState {
        case .start: do {
            switch via {
            case .initialize: do {
                if let acct = self.accountStorage.read() {
                    account = acct
                    return Event.accountRestored
                } else {
                    return Event.accountNotFound
                }
            }
            default: return nil
            }
        }
        case .notAuthenticated: do {
            switch via {
            case .logout: do {
                // Clean up internal account state and destroy the current FxA device record.
                do {
                    try requireAccount().disconnectSync()
                    log("Disconnected FxA account")
                } catch {
                    log("Failed to fully disconnect the FxA account: \(error).")
                }
                profile = nil
                constellation = nil
                accountStorage.clear()
                // If we cannot instanciate FxA something is *really* wrong, crashing is a valid option.
                account = createAccount()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .accountLoggedOut,
                        object: nil
                    )
                }
            }
            case .accountNotFound: do {
                account = createAccount()
            }
            default: break // Do nothing
            }
        }
        case .authenticatedNoProfile: do {
            switch via {
            case let .authenticated(authData): do {
                log("Registering persistence callback")
                requireAccount().registerPersistCallback(statePersistenceCallback)

                log("Completing oauth flow")
                do {
                    try requireAccount().completeOAuthFlowSync(code: authData.code, state: authData.state)
                } catch {
                    // Reasons this can fail:
                    // - network errors
                    // - unknown auth state
                    //  -- authenticating via web-content; we didn't beginOAuthFlowAsync
                    log("Error completing OAuth flow: \(error)")
                    // XXX: Could we do better than logging?
                }

                os_log("Initializing device")
                requireConstellation().initDevice(name: deviceConfig.name, type: deviceConfig.type, capabilities: deviceConfig.capabilities)

                postAuthenticated(authType: authData.authType)

                return Event.fetchProfile
            }
            case .accountRestored: do {
                log("Registering persistence callback")
                requireAccount().registerPersistCallback(statePersistenceCallback)

                os_log("Ensuring device capabilities...")
                requireConstellation().ensureCapabilities(capabilities: deviceConfig.capabilities)

                postAuthenticated(authType: .existingAccount)

                return Event.fetchProfile
            }
            case .recoveredFromAuthenticationProblem: do {
                log("Registering persistence callback")
                requireAccount().registerPersistCallback(statePersistenceCallback)

                os_log("Initializing device")
                requireConstellation().initDevice(name: deviceConfig.name, type: deviceConfig.type, capabilities: deviceConfig.capabilities)

                postAuthenticated(authType: .recovered)

                return Event.fetchProfile
            }
            case .fetchProfile: do {
                // Profile fetching and account authentication issues:
                // https://github.com/mozilla/application-services/issues/483
                log("Fetching profile...")

                do {
                    profile = try requireAccount().getProfileSync()
                } catch {
                    return Event.failedToFetchProfile
                }
                return Event.fetchedProfile
            }
            default: break // Do nothing
            }
        }
        case .authenticatedWithProfile: do {
            switch via {
            case .fetchedProfile: do {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .accountProfileUpdate,
                        object: nil,
                        userInfo: ["profile": self.profile!]
                    )
                }
            }
            default: break // Do nothing
            }
        }
        case .authenticationProblem:
            switch via {
            case .authenticationError: do {
                // Somewhere in the system, we've just hit an authentication problem.
                // There are two main causes:
                // 1) an access token we've obtain from fxalib via 'getAccessToken' expired
                // 2) password was changed, or device was revoked
                // We can recover from (1) and test if we're in (2) by asking the fxalib.
                // If it succeeds, then we can go back to whatever
                // state we were in before. Future operations that involve access tokens should
                // succeed.

                func onError() {
                    // We are either certainly in the scenario (2), or were unable to determine
                    // our connectivity state. Let's assume we need to re-authenticate.
                    // This uncertainty about real state means that, hopefully rarely,
                    // we will disconnect users that hit transient network errors during
                    // an authorization check.
                    // See https://github.com/mozilla-mobile/android-components/issues/3347
                    os_log("Unable to recover from an auth problem.")
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .accountAuthProblems,
                            object: nil
                        )
                    }
                }

                do {
                    let info = try requireAccount().checkAuthorizationStatusSync()
                    if !info.active {
                        onError()
                    }
                    try requireAccount().clearAccessTokenCacheSync()
                    // Make sure we're back on track by re-requesting the profile access token.
                    _ = try requireAccount().getAccessTokenSync(scope: Scope.profile)
                    return .recoveredFromAuthenticationProblem
                } catch {
                    onError()
                }
                return nil
            }
            default: break // Do nothing
            }
        }
        return nil
    }

    internal func createAccount() -> FirefoxAccount {
        return try! FirefoxAccount(config: config)
    }

    internal func postAuthenticated(authType: FxaAuthType) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .accountAuthenticated,
                object: nil,
                userInfo: ["authType": authType]
            )
        }
        requireConstellation().refreshState()
    }

    internal func requireAccount() -> FirefoxAccount {
        if let acct = account {
            return acct
        }
        preconditionFailure("initialize() must be called first.")
    }

    internal func requireConstellation() -> DeviceConstellation {
        if let cstl = constellation {
            return cstl
        }
        preconditionFailure("account must be set (sets constellation).")
    }

    // swiftlint:enable function_body_length
}

internal func log(_ msg: String) {
    os_log("%@", msg)
}

class FxAStatePersistenceCallback: PersistCallback {
    weak var manager: FxaAccountManager?

    public init(manager: FxaAccountManager) {
        self.manager = manager
    }

    func persist(json: String) {
        manager?.accountStorage.write(json)
    }
}

/**
 * States of the [FxaAccountManager].
 */
internal enum AccountState {
    case start
    case notAuthenticated
    case authenticationProblem
    case authenticatedNoProfile
    case authenticatedWithProfile
}

/**
 * Base class for [FxaAccountManager] state machine events.
 * Events aren't a simple enum class because we might want to pass data along with some of the events.
 */
internal enum Event {
    case initialize
    case accountNotFound
    case accountRestored
    case authenticated(authData: FxaAuthData)
    case authenticationError /* (error: AuthException) */
    case recoveredFromAuthenticationProblem
    case fetchProfile
    case fetchedProfile
    case failedToFetchProfile
    case logout
}

public enum FxaAuthType {
    case existingAccount
    case signin
    case signup
    case pairing
    case recovered
    case other(reason: String)

    internal static func fromActionQueryParam(_ action: String) -> FxaAuthType {
        switch action {
        case "signin": return .signin
        case "signup": return .signup
        case "pairing": return .pairing
        default: return .other(reason: action)
        }
    }
}

public struct FxaAuthData {
    public let code: String
    public let state: String
    public let authType: FxaAuthType

    public init(code: String, state: String, actionQueryParam: String) {
        self.code = code
        self.state = state
        authType = FxaAuthType.fromActionQueryParam(actionQueryParam)
    }
}

public struct DeviceConfig {
    let name: String
    let type: DeviceType
    let capabilities: [DeviceCapability]

    public init(name: String, type: DeviceType, capabilities: [DeviceCapability]) {
        self.name = name
        self.type = type
        self.capabilities = capabilities
    }
}

public enum Scope {
    // Necessary to fetch a profile.
    public static let profile: String = "profile"
    // Necessary to obtain sync keys.
    public static let sync: String = "https://identity.mozilla.com/apps/oldsync"
}
