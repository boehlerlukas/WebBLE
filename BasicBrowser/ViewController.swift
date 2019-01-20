//
//  Copyright © 2017 Paul Theriault & David Park. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

import UIKit
import WebKit

class ViewController: UIViewController, UITextFieldDelegate, WKNavigationDelegate, WKUIDelegate, UIScrollViewDelegate, WBNavigationBarDelegate {

    enum prefKeys: String {
        case bookmarks
        case consoleOpen
        case lastLocation
        case version
    }

    // MARK: - Properties
    let currentPrefVersion = 1

    // MARK: IBOutlets
    @IBOutlet weak var locationTextField: UITextField!
    @IBOutlet var tick: UIImageView!
    @IBOutlet var webViewContainer: UIView!
    @IBOutlet var goBackButton: UIBarButtonItem!
    @IBOutlet var goForwardButton: UIBarButtonItem!
    @IBOutlet var refreshButton: UIBarButtonItem!
    @IBOutlet var showConsoleButton: UIBarButtonItem!
    @IBOutlet var webViewBottomConstraint: NSLayoutConstraint!
    @IBOutlet var webView: WBWebView!
    @IBOutlet var logManager: WBLogManager!
    @IBOutlet var extraShowBarsView: UIView!

    var initialURL: URL?

    var bookmarksManager = BookmarksManager(
        userDefaults: UserDefaults.standard, key: prefKeys.bookmarks.rawValue)
    var wbManager: WBManager? {
        didSet {
            self.webView.wbManager = wbManager
        }
    }

    var consoleViewContainerController: ConsoleViewContainerController? = nil

    var scrollingFromTop = false
    var scrollingFromBottom = false
    let showBarsOnFlickUpDown = false

    override func prefersHomeIndicatorAutoHidden() -> Bool {
        return self.navigationController?.isNavigationBarHidden ?? false
    }
    override var prefersStatusBarHidden: Bool {
        get {
            return true
        }
    }

    // MARK: - API
    // MARK: IBActions
    @IBAction func addBookmark() {
        guard
            let title = self.webView.title,
            !title.isEmpty,
            let url = self.webView.url,
            url.absoluteString != "about:blank"
        else {
            let uac = UIAlertController(title: "Unable to bookmark", message: "This page cannot be bookmarked as it has an invalid title or URL, or was a failed navigation", preferredStyle: .alert)
            uac.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            self.present(uac, animated: true, completion: nil)
            return
        }

        self.bookmarksManager.addBookmarks([WBBookmark(title: title, url: url)])
        FlashAnimation(withView: self.tick).go()
    }
    @IBAction func showBars() {
        let nc = self.navigationController!
        nc.setToolbarHidden(false, animated: true)
        nc.setNavigationBarHidden(false, animated: true)
        self.setHidesOnSwipesFromScrollView(self.webView.scrollView)
    }
    @IBAction func reload() {
        if (self.webView?.url?.absoluteString ?? "about:blank") == "about:blank",
            let text = self.locationTextField.text,
            !text.isEmpty {
            self.loadLocation(text)
        } else {
            self.webView.reload()
        }
    }
    @IBAction func toggleConsole() {
        if self.consoleViewContainerController != nil {
            self.hideConsole()
        } else {
            self.showConsole()
        }
    }

    // MARK: - Segue handling
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if let bvc = segue.destination as? BookmarksViewController {
            bvc.bookmarksManager = self.bookmarksManager
        }
    }
    @IBAction func unwindToWBController(sender: UIStoryboardSegue) {
        if let bvc = sender.source as? BookmarksViewController,
            let tv = bvc.view as? UITableView,
            let ip = tv.indexPathForSelectedRow {
            if ip.item >= self.bookmarksManager.bookmarks.count {
                NSLog("Selected bookmark is out of range")
            }
            else {
                self.webView.load(URLRequest(url: self.bookmarksManager.bookmarks[ip.item].url))
            }
        }
    }

    // MARK: - Event handling
    override func viewDidLoad() {
        super.viewDidLoad()

        let ud = UserDefaults.standard

        // connect view to other objects
        self.locationTextField.delegate = self
        self.webView.wbManager = self.wbManager
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
        self.webView.scrollView.delegate = self
        self.webView.scrollView.clipsToBounds = false

        for path in ["canGoBack", "canGoForward"] {
            self.webView.addObserver(self, forKeyPath: path, options: .new, context: nil)
        }

        self.loadPreferences()

        // Load last location
        if let url = initialURL {
            loadURL(url)
        }
        else {
            var lastLocation: String
            if let prefLoc = ud.value(forKey: ViewController.prefKeys.lastLocation.rawValue) as? String {
            lastLocation = prefLoc
            } else {
                let svers = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
                lastLocation = "https://www.greenparksoftware.co.uk/projects/webble/\(svers)"
            }
            self.loadLocation(lastLocation)
        }

        self.goBackButton.target = self.webView
        self.goBackButton.action = #selector(self.webView.goBack)
        self.goForwardButton.target = self.webView
        self.goForwardButton.action = #selector(self.webView.goForward)
        self.refreshButton.target = self.webView
        self.refreshButton.action = #selector(self.webView.reload)

        if ud.bool(forKey: prefKeys.consoleOpen.rawValue) {
            self.showConsole()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        let nc = self.navigationController as! NavigationViewController
        nc.navigationBarDelegate = self
        self.showBars()
    }
    override func viewWillDisappear(_ animated: Bool) {
        let nc = self.navigationController as! NavigationViewController
        nc.navigationBarDelegate = nil
        super.viewWillDisappear(animated)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        self.loadLocation(textField.text!)
        return true
    }
    
    func loadLocation(_ location: String) {
        var location = location
        if !location.hasPrefix("http://") && !location.hasPrefix("https://") {
            location = "https://" + location
        }
        guard let url = URL(string: location) else {
            NSLog("Failed to convert location \(location) into a URL")
            return
        }
        loadURL(url)
    }

    func loadURL(_ url: URL) {
        guard self.isViewLoaded else {
            self.initialURL = url
            return
        }
        self.setLocationText(url.absoluteString)
        self.webView.load(URLRequest(url: url))
    }
    func setLocationText(_ text: String) {
        self.locationTextField.text = text
        self.locationTextField.sizeToFit()
    }

    // MARK: - WKNavigationDelegate
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {

        NSLog("Did start provisional nav")
        self.wbManager?.clearState()
        self.wbManager = WBManager()
        self.logManager.clearLogs()
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.webView.enableBluetoothInView()
        if let urlString = webView.url?.absoluteString,
            urlString != "about:blank" {
            self.setLocationText(urlString)
            UserDefaults.standard.setValue(urlString, forKey: ViewController.prefKeys.lastLocation.rawValue)
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        webView.loadHTMLString("<p>Fail Navigation: \(error.localizedDescription)</p>", baseURL: nil)
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        webView.loadHTMLString("<p>Fail Provisional Navigation: \(error.localizedDescription)</p>", baseURL: nil)
    }

    // MARK: - WKUIDelegate
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: (@escaping () -> Void)) {
        let alertController = UIAlertController(
            title: frame.request.url?.host, message: message,
            preferredStyle: .alert)
        alertController.addAction(UIAlertAction(
            title: "OK", style: .default, handler: {_ in completionHandler()}))
        self.present(alertController, animated: true, completion: nil)
    }

    // MARK: - UIScrollViewDelegate
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        let yOffset = scrollView.contentOffset.y
        let frameHeight = scrollView.frame.size.height
        let contentHeight = scrollView.contentSize.height

        if yOffset < 5.0 {
            self.scrollingFromTop = true
            self.scrollingFromBottom = false
        } else if contentHeight - (yOffset + frameHeight) < 5.0 {
            self.scrollingFromTop = false
            self.scrollingFromBottom = true
        } else {
            self.scrollingFromTop = false
            self.scrollingFromBottom = false
        }
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        let yOffset = scrollView.contentOffset.y
        let frameHeight = scrollView.frame.size.height
        let contentHeight = scrollView.contentSize.height

        if !decelerate {
            self.setHidesOnSwipesFromScrollView(scrollView)
        }

        if self.showBarsOnFlickUpDown && self.scrollingFromTop && yOffset < 0.0 {
            self.showBars()
        }
        if self.showBarsOnFlickUpDown && self.scrollingFromBottom && yOffset + frameHeight > contentHeight {
            self.showBars()
        }
        self.scrollingFromTop = false
        self.scrollingFromBottom = false
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        self.setHidesOnSwipesFromScrollView(scrollView)
    }

    // MARK: - WBNavigationBarDelegate
    func navBarIsHiddenDidChange(_ hidden: Bool) {
        self.setNeedsUpdateOfHomeIndicatorAutoHidden()
        if hidden {
            self.extraShowBarsView.isHidden = false
        } else {
            self.extraShowBarsView.isHidden = true
        }
    }

    // MARK: - Observe protocol
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard
            let defKeyPath = keyPath,
            let defChange = change
        else {
            NSLog("Unexpected change with either no keyPath or no change dictionary!")
            return
        }

        switch defKeyPath {
        case "canGoBack":
            self.goBackButton.isEnabled = defChange[NSKeyValueChangeKey.newKey] as! Bool
        case "canGoForward":
            self.goForwardButton.isEnabled = defChange[NSKeyValueChangeKey.newKey] as! Bool
        default:
            NSLog("Unexpected change observed by ViewController: \(defKeyPath)")
        }
    }

    // MARK: - Private
    private func loadPreferences() {

        // Sort out the preferences we have.
        let ud = UserDefaults.standard

        let prefsVersion = ud.integer(forKey: ViewController.prefKeys.version.rawValue)

        var hadPrefs = false
        if let bma = ud.array(forKey: ViewController.prefKeys.bookmarks.rawValue) as? [[String: String]] {
            self.bookmarksManager.mergeInBookmarkDicts(bookmarkDicts: bma)
            hadPrefs = true
        }

        // Merge in any defaults.
        let mb = Bundle.main
        guard let defPlistURL = mb.url(forResource: "Defaults", withExtension: "plist"),
            let defDict = NSDictionary(contentsOf: defPlistURL) else {
                assert(false, "Unexpectedly couldn't find defaults")
                return
        }

        let range = (!hadPrefs ? 0 : prefsVersion + 1) ..< self.currentPrefVersion + 1

        for pref in range {
            guard let vDict = defDict.value(forKey: "\(pref)") as? [String: Any] else {
                continue
            }
            vDict.forEach({
                key, object in
                guard let pKey = ViewController.prefKeys(rawValue: key)
                    else {
                        return
                }

                switch pKey {
                case .bookmarks:
                    guard
                        let bdicts = object as? [[String: String]]
                        else {
                            assert(false, "Unexpectedly couldn't find bookmarks in defaults")
                            return
                    }
                    self.bookmarksManager.mergeInBookmarkDicts(bookmarkDicts: bdicts)
                default:
                    return
                }
            })
        }

        // Set the preferences version to be up to date.
        ud.set(self.currentPrefVersion, forKey: ViewController.prefKeys.version.rawValue)
    }
    func showConsole() {
        guard let cvcont =  self.storyboard?.instantiateViewController(withIdentifier: "ConsoleViewContainer") as? ConsoleViewContainerController else {
            NSLog("Unable to load ConsoleViewContainer from the storyboard")
            return
        }
        NSLayoutConstraint.deactivate(
            [self.webViewBottomConstraint]
        )
        self.addChildViewController(cvcont)

        self.view.insertSubview(cvcont.view, at: self.view.subviews.firstIndex(of: self.extraShowBarsView)!)

        // after adding the subview the IB outlets will be joined up,
        // so we can add the logger direct to the console view controller
        cvcont.wbLogManager = self.webView.logManager

        cvcont.view.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor).isActive = true
        NSLayoutConstraint.activate([
            NSLayoutConstraint(item: cvcont.view, attribute: .top, relatedBy: .equal, toItem: self.webViewContainer, attribute: .bottom, multiplier: 1.0, constant: 0.0),
            NSLayoutConstraint(item: cvcont.view, attribute: .leading, relatedBy: .equal, toItem: self.view, attribute: .leading, multiplier: 1.0, constant: 0.0),
            NSLayoutConstraint(item: cvcont.view, attribute: .trailing, relatedBy: .equal, toItem: self.view, attribute: .trailing, multiplier: 1.0, constant: 0.0),
            ])

        self.consoleViewContainerController = cvcont
        UserDefaults.standard.setValue(true, forKey: prefKeys.consoleOpen.rawValue)
    }
    func hideConsole() {
        let cvcont = self.consoleViewContainerController!
        NSLayoutConstraint.deactivate(cvcont.view.constraints)
        cvcont.view.removeFromSuperview()
        cvcont.removeFromParentViewController()
        self.consoleViewContainerController = nil;
        NSLayoutConstraint.activate([self.webViewBottomConstraint])
        UserDefaults.standard.setValue(false, forKey: prefKeys.consoleOpen.rawValue)
    }
    func setHidesOnSwipesFromScrollView(_ scrollView: UIScrollView) {
        // Due to an apparent bug this should not be called when the toolbar / navbar are animating up or down as far as possible as that seems to cause a crash
        let yOffset = scrollView.contentOffset.y
        let frameHeight = scrollView.frame.size.height
        let contentHeight = scrollView.contentSize.height
        let nc = self.navigationController!

        let bottomMarginNotToHideSwipesIn: CGFloat = 100.0

        if yOffset + frameHeight > (
            contentHeight > bottomMarginNotToHideSwipesIn
                ? contentHeight - bottomMarginNotToHideSwipesIn
                : 0
        ) {
            if nc.hidesBarsOnSwipe {
                nc.hidesBarsOnSwipe = false
            }
        } else {
            if !nc.hidesBarsOnSwipe {
                nc.hidesBarsOnSwipe = true
            }
        }
    }
}
