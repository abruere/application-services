/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import MozillaAppServices

class ViewController: UIViewController, AccountObserver {
    
    lazy var fxa: FxaAccountManager = {
        let delegate = UIApplication.shared.delegate as! AppDelegate
        return delegate.fxa
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        
        fxa.register(observer: self)
    }
    
    func buildUI() {
        self.view.backgroundColor = .white
        clearSubViews()
        
        let profile = fxa.accountProfile()
        
        if fxa.hasAccount() {
            if !fxa.accountNeedsReauth() { // Account OK
                let label = UILabel(frame: CGRect(x: 0, y: 0, width: 200, height: 21))
                label.center = CGPoint(x: 160, y: 285)
                label.textAlignment = .center
                label.text = "Connected to \(profile?.email ?? "FxA")"
                self.view.addSubview(label)
            } else { // Needs reauth
                let button = UIButton(frame: CGRect(x: 100, y: 100, width: 100, height: 50))
                button.center = self.view.center
                button.backgroundColor = .blue
                button.setTitle("Reconnect to \(profile?.email ?? "FxA")", for: [])
                button.addTarget(self, action: #selector(onButtonPressed), for: .touchUpInside)

                self.view.addSubview(button)
            }
            
            let button = UIButton(frame: CGRect(x: 100, y: 100, width: 100, height: 50))
            button.center = self.view.center
            button.backgroundColor = .blue
            button.setTitle("Disconnect", for: [])
            button.addTarget(self, action: #selector(onDisconnectBtn), for: .touchUpInside)

            self.view.addSubview(button)
            
        } else { // Signed out
            let button = UIButton(frame: CGRect(x: 100, y: 100, width: 100, height: 50))
            button.center = self.view.center
            button.backgroundColor = .blue
            button.setTitle("Log-in", for: [])
            button.addTarget(self, action: #selector(onButtonPressed), for: .touchUpInside)

            self.view.addSubview(button)
        }
    }
    
    func onLoggedOut() {
        print("onLoggedOut()")
        buildUI()
    }

    func onAuthenticationProblems() {
        print("onAuthenticationProblems()")
        buildUI()
    }

    func onAuthenticated(authType: FxaAuthType) {
        print("onAuthenticated()")
        buildUI()
    }

    func onProfileUpdated(profile: MozillaAppServices.Profile) {
        print("onProfileUpdated()")
        buildUI()
    }
    
    func clearSubViews() {
        self.view.subviews.forEach { $0.removeFromSuperview() }
    }

    @objc func onButtonPressed(sender: UIButton!) {
        fxa.beginAuthentication { authURL in
            self.navigationController?.pushViewController(LoginView(authUrl: try! authURL.get()), animated: true)
        }
    }

    @objc func onDisconnectBtn(sender: UIButton!) {
        fxa.logout { _ in
            // Logged out!
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }


}

