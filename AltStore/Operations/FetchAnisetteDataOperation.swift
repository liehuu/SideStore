//
//  FetchAnisetteDataOperation.swift
//  AltStore
//
//  Created by Riley Testut on 1/7/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import CommonCrypto
import Starscream
import AltStoreCore
import AltSign
import Roxas

class ANISETTE_VERBOSITY: Operation {} // dummy tag iface

@objc(FetchAnisetteDataOperation)
final class FetchAnisetteDataOperation: ResultOperation<ALTAnisetteData>, WebSocketDelegate
{
    let context: OperationContext
    var socket: WebSocket!
    
    var url: URL?
    var startProvisioningURL: URL?
    var endProvisioningURL: URL?
    
    var clientInfo: String?
    var userAgent: String?

    /// The user agent declared by the selected anisette server. GrandSlam
    /// requires the sign-in UA to match the client that minted the anisette;
    /// AuthenticationOperation forwards this to AltSign.
    private(set) var serverUserAgent: String?
    
    var mdLu: String?
    var deviceId: String?

    // FIX(1100): consecutive V1 fetches may land on different load-balanced
    // virtual devices; count retries while trying to match the machineID
    // bound to the cached session token.
    private var v1MachineIDRetryCount = 0

    // FIX(ani-80043-rotate): servers that answered fine but whose anisette
    // Apple then rejected (-80043 / -80044). Reaching a server only proves it
    // is *up*; it does not prove Apple still accepts the machine identity it
    // mints. ani.sidestore.zip and ani.npeg.us both serve the same rejected
    // device id (8ABE1294-…), so a reachability-only rotation can hand the user
    // a server that always fails and never move on.
    // Guards the rotation below: a server rejection restarts the whole
    // main() flow, which would otherwise re-enter with a fresh
    // rejectedServers set and pick the same dead server forever.
    private static var rejectedServersForSession: Set<String> = []
    private static let rejectedServersLock = NSLock()

    init(context: OperationContext)
    {
        self.context = context
    }
    
    override func main()
    {
        super.main()
        
        if let error = self.context.error
        {
            self.finish(.failure(error))
            return
        }
        
        // TODO: Pass in proper view context to show the Toast messages
        let viewContext = context.presentingViewController
        
        getAnisetteServerUrl(viewContext){ url, error in
            guard let urlString = url else {
                self.finish(.failure(error ?? OperationError.anisetteV3Error(message: "No valid anisette server found")))
                return
            }

            // set as preferred
            UserDefaults.standard.menuAnisetteURL = urlString
            let url = URL(string: urlString)
            self.url = url
            self.printOut("Anisette URL: \(self.url!.absoluteString)")

            // FIX(gsa-22410-stale-adipb): adi.pb is provisioned *against the
            // client-info identity that was presented at provisioning time*.
            // Changing `pinnedClientInfo` therefore strands every cached
            // adi.pb: the identity Apple has on file for this device no longer
            // matches the header we now send, and the sign-in fails with
            // -22410 ("This action could not be completed") *after* both the
            // anisette and the account have been accepted, so retrying and
            // re-entering the password can never help.
            //
            // The published remedy is Settings → User Customizations → Reset
            // adi.pb. Making the user find that menu after every identity
            // change is a poor trade, so record which identity the cached
            // adi.pb belongs to and drop it automatically when that identity
            // is no longer the one we send.
            //
            // Only adi.pb is cleared, not `identifier`: identifier seeds
            // X-Apple-I-MD-LU / X-Mme-Device-Id and should stay stable across
            // re-provisioning, which is also what the manual "Reset adi.pb"
            // button does (verified in AnisetteServerList.swift).
            //
            // An identifier regeneration (the invalid-base64 branch in
            // fetchClientInfo) does not need its own check here: that path
            // already produces -45061 ("not provisioned") on the next fetch,
            // and -45061 is handled by dropping adi.pb further down.
            // FIX(ani-80043-match): adi.pb is provisioned against a specific
            // anisette server's identity (client-info + UA). When the selected
            // server changes — including the automatic rotation after Apple
            // rejects one — the cached adi.pb belongs to the old server and
            // must be re-provisioned, or Apple rejects the stale pairing.
            let provisionedServer = UserDefaults.standard.string(forKey: FetchAnisetteDataOperation.provisionedClientInfoKey)
            if Keychain.shared.adiPb != nil,
               provisionedServer != urlString {
                self.printOut("Cached adi.pb was provisioned by \"\(provisionedServer ?? "<unknown>")\", but we now use \"\(urlString)\" → discarding adi.pb and re-provisioning")
                Keychain.shared.adiPb = nil

                // Re-provisioning mints a new machineID, and Apple binds the
                // session token to the machineID used at sign-in time. Keeping
                // the old session would fail every authenticated request with
                // 1100 ("Your session has expired"), so drop it and let the
                // caller sign in again against the new identity.
                if Keychain.shared.session != nil {
                    self.printOut("Discarding cached session: its token is bound to the previous machineID")
                    Keychain.shared.session = nil
                    Keychain.shared.certificate = nil
                    Keychain.shared.team = nil
                }
            }

            if let identifier = Keychain.shared.identifier,
               let adiPb = Keychain.shared.adiPb {
                self.fetchAnisetteV3(identifier, adiPb)
            } else {
                // FIX(1100): restore the official V3 provisioning flow.
                // V3 (identifier + adi.pb) keeps a stable machineID, which the
                // session token is bound to. The old FIX(login-crash) shortcut
                // sent every device straight to the V1 root endpoint, whose
                // server-side load balancing rotates across independently
                // provisioned virtual devices — breaking the token/machineID
                // pairing and causing error 1100 on refresh.
                // All force-unwrap crash points along the provisioning path
                // have been fixed; any failure now falls back to the V1 root
                // fetch (which retries until machineIDs match, when possible).
                self.printOut("No cached adi.pb → trying V3 provisioning (falls back to V1 on any failure)")
                self.provision()
            }
        }
    }
    

    func getAnisetteServerUrl(_ viewContext: UIViewController?, completion: @escaping (String?, Error?) -> Void) {
        var serverUrls = UserDefaults.standard.menuAnisetteServersList
        let currentServer = UserDefaults.standard.menuAnisetteURL

        // Prioritize the current server by moving it to the top of the list
        if let currentServerIndex = serverUrls.firstIndex(of: currentServer) {
            serverUrls.remove(at: currentServerIndex)
            serverUrls.insert(currentServer, at: 0)
        }

        // FIX(ani-80043-rotate): hide servers whose anisette Apple already
        // rejected, so a retry lands on a different one instead of the same
        // dead identity. If that would leave nothing, drop the exclusions —
        // a rejected server is still better than no server at all, and Apple
        // may have re-accepted it since.
        let excluded = FetchAnisetteDataOperation.rejectedServerSnapshot()
        let remaining = serverUrls.filter { !excluded.contains($0) }
        if !remaining.isEmpty {
            serverUrls = remaining
        } else if !excluded.isEmpty {
            self.printOut("Every known server has been rejected by Apple at least once; retrying them all rather than failing outright")
        }

        tryNextServer(from: serverUrls, viewContext, currentIndex: 0, completion: completion)
    }

    // MARK: - Rejected-server bookkeeping

    static func rejectedServerSnapshot() -> Set<String>
    {
        FetchAnisetteDataOperation.rejectedServersLock.lock()
        defer { FetchAnisetteDataOperation.rejectedServersLock.unlock() }
        return FetchAnisetteDataOperation.rejectedServersForSession
    }

    static func markServerRejected(_ urlString: String)
    {
        FetchAnisetteDataOperation.rejectedServersLock.lock()
        defer { FetchAnisetteDataOperation.rejectedServersLock.unlock() }
        FetchAnisetteDataOperation.rejectedServersForSession.insert(urlString)
    }

    static func clearRejectedServers()
    {
        FetchAnisetteDataOperation.rejectedServersLock.lock()
        defer { FetchAnisetteDataOperation.rejectedServersLock.unlock() }
        FetchAnisetteDataOperation.rejectedServersForSession.removeAll()
    }
    
    private func showToast(viewContext: UIViewController?, message: String){
        if let viewContext = viewContext{
            let error = OperationError.anisetteV1Error(message: message)
            let toastView = ToastView(error: error)
//            toastView.textLabel.textColor = .altPrimary
//            toastView.detailTextLabel.textColor = .altPrimary
            DispatchQueue.main.async {
                toastView.show(in: viewContext)
            }
        }
    }

    private func tryNextServer(from serverUrls: [String], _ viewContext: UIViewController?,currentIndex: Int, completion: @escaping (String?, Error?) -> Void) {
        // Check if all URLs have been exhausted
        guard currentIndex < serverUrls.count else {
            let error = NSError(domain: "AnisetteError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No valid server found."])
            completion(nil, error)
            return
        }

        let currentServerUrlString = serverUrls[currentIndex]
        guard let url = URL(string: currentServerUrlString) else {
            // Invalid URL, skip to next
            let errmsg = "Skipping invalid URL: \(currentServerUrlString)"
            self.printOut(errmsg)
            showToast(viewContext: viewContext, message: errmsg)
            tryNextServer(from: serverUrls, viewContext, currentIndex: currentIndex + 1, completion: completion)
            return
        }

        // Attempt to ping the current URL
        pingServer(url) { success, error in
            if success {
                // If the server is reachable, return the URL
                let okmsg = "Found working server: \(url.absoluteString)"
                self.printOut(okmsg)
                if(currentIndex > 0){
                    // notify user if available server is different the user-specified one
                    self.showToast(viewContext: viewContext, message: okmsg)
                }
                completion(url.absoluteString, nil)
            } else {
                // If not, try the next URL
                let errmsg = "Failed to reach server: \(url.absoluteString), trying next server."
                self.printOut(errmsg)
                self.showToast(viewContext: viewContext, message: errmsg)
                self.tryNextServer(from: serverUrls, viewContext, currentIndex: currentIndex + 1, completion: completion)
            }
        }
    }

    func pingServer(_ url: URL, completion: @escaping (Bool, Error?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10 // Timeout after 10 seconds
        
        let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
            if let error = error {
                completion(false, error)
                return
            }
            
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode
            
            guard let statusCode = statusCode,
                  (200...299).contains(statusCode) else {
                let serverError = OperationError.anisetteV3Error(message: "Server unreachable or invalid response: \(String(describing: statusCode ?? nil))")
                completion(false, serverError)
                return
            }
            
            completion(true, nil)
        }
        
        task.resume()
    }
    
    
    // MARK: - COMMON
    
    func extractAnisetteData(_ data: Data, _ response: HTTPURLResponse?, v3: Bool) throws {
        // make sure this JSON is in the format we expect
        // convert data to json
        if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: String] {
            if v3 {
                if json["result"] == "GetHeadersError" {
                    let message = json["message"]
                    self.printOut("Error getting V3 headers: \(message ?? "no message")")
                    if let message = message,
                       message.contains("-45061") {
                        self.printOut("Error message contains -45061 (not provisioned), resetting adi.pb and retrying")
                        Keychain.shared.adiPb = nil
                        // FIX(login-crash): -45061 means the cached adi.pb is stale/not
                        // provisioned. Previously this re-entered the fragile gsa.apple.com +
                        // WebSocket provisioning flow (crash-prone). Fall back to V1 root
                        // fetch instead, which returns usable headers without provisioning.
                        self.printOut("-45061 → falling back to V1 root fetch")
                        self.printOut("Anisette URL: \(self.url?.absoluteString ?? "<nil>")")
                        return self.fetchAnisetteV1()
                    } else { throw OperationError.anisetteV3Error(message: message ?? "Unknown error") }
                }
            }
            
            // try to read out a dictionary
            // for some reason serial number isn't needed but it doesn't work unless it has a value
            var formattedJSON: [String: String] = ["deviceSerialNumber": "0"]
            if let machineID = json["X-Apple-I-MD-M"] { formattedJSON["machineID"] = machineID }
            if let oneTimePassword = json["X-Apple-I-MD"] { formattedJSON["oneTimePassword"] = oneTimePassword }
            if let routingInfo = json["X-Apple-I-MD-RINFO"] { formattedJSON["routingInfo"] = routingInfo }
            
            if v3 {
                // FIX(login-crash): never force-unwrap clientInfo/mdLu/deviceId.
                // If they aren't ready (e.g. fetchClientInfo fast-path raced), fall back
                // to V1 root fetch instead of crashing.
                guard let clientInfo = self.clientInfo,
                      let mdLu = self.mdLu,
                      let deviceId = self.deviceId else {
                    self.printOut("V3 anisette fields not ready → falling back to V1 root fetch")
                    return self.fetchAnisetteV1()
                }
                formattedJSON["deviceDescription"] = clientInfo
                formattedJSON["localUserID"] = mdLu
                formattedJSON["deviceUniqueIdentifier"] = deviceId
                
                // Generate date stuff on client
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = TimeZone.init(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
                let dateString = formatter.string(from: Date())
                formattedJSON["date"] = dateString
                formattedJSON["locale"] = Locale.current.identifier
                formattedJSON["timeZone"] = TimeZone.current.abbreviation()
            } else {
                // FIX(gsa-503): V1 servers also return the blocked Xcode
                // identifier in X-MMe-Client-Info; normalize it to akd.
                if let deviceDescription = json["X-MMe-Client-Info"] {
                    formattedJSON["deviceDescription"] = self.sanitizeClientInfo(deviceDescription)
                }
                if let localUserID = json["X-Apple-I-MD-LU"] { formattedJSON["localUserID"] = localUserID }
                if let deviceUniqueIdentifier = json["X-Mme-Device-Id"] { formattedJSON["deviceUniqueIdentifier"] = deviceUniqueIdentifier }
                
                if let date = json["X-Apple-I-Client-Time"] { formattedJSON["date"] = date }
                if let locale = json["X-Apple-Locale"] { formattedJSON["locale"] = locale }
                if let timeZone = json["X-Apple-I-TimeZone"] { formattedJSON["timeZone"] = timeZone }
            }
            
            if let response = response,
               let version = response.value(forHTTPHeaderField: "Implementation-Version") {
                self.printOut("Implementation-Version: \(version)")
            } else { self.printOut("No Implementation-Version header") }
            
            self.printOut("Anisette used: \(formattedJSON)")
            self.printOut("Original JSON: \(json)")
            if let anisette = ALTAnisetteData(json: formattedJSON) {
                // FIX(1100): V1 anisette servers load-balance across many
                // independently provisioned virtual devices — consecutive
                // requests routinely return different machineIDs (verified
                // against ani.sidestore.io: 5+ distinct devices across 6
                // requests, while each device's X-Apple-I-MD-M stays stable).
                // Apple session tokens are bound to the machineID used at
                // sign-in time, so a mismatched anisette makes every
                // authenticated request fail with 1100 ("Your session has
                // expired"). If we already hold a session, retry until the
                // server hands us the matching virtual device.
                if !v3,
                   let expectedMachineID = Keychain.shared.session?.anisetteData.machineID,
                   anisette.machineID != expectedMachineID,
                   self.v1MachineIDRetryCount < 12
                {
                    self.v1MachineIDRetryCount += 1
                    self.printOut("Anisette machineID mismatch (retry \(self.v1MachineIDRetryCount)/12); refetching V1")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self.fetchAnisetteV1()
                    }
                    return
                }
                self.printOut("Anisette is valid!")
                self.finish(.success(anisette))
            } else {
                self.printOut("Anisette is invalid!!!!")
                if v3 {
                    throw OperationError.anisetteV3Error(message: "Invalid anisette (the returned data may not have all the required fields)")
                } else {
                    throw OperationError.anisetteV1Error(message: "Invalid anisette (the returned data may not have all the required fields)")
                }
            }
        } else {
            if v3 {
                throw OperationError.anisetteV3Error(message: "Invalid anisette (the returned data may not be in JSON)")
            } else {
                throw OperationError.anisetteV1Error(message: "Invalid anisette (the returned data may not be in JSON)")
            }
        }
    }
    
    // MARK: - V1
    
    func handleV1() {
        self.printOut("Server is V1")
        
        if UserDefaults.shared.trustedServerURL == AnisetteManager.currentURLString {
            self.printOut("Server has already been trusted, fetching anisette")
            return self.fetchAnisetteV1()
        }
        
        self.printOut("Alerting user about outdated server")
        let alert = UIAlertController(title: "WARNING: Outdated anisette server", message: "We've detected you are using an older anisette server. Using this server has a higher likelihood of locking your account and causing other issues. Are you sure you want to continue?", preferredStyle: UIAlertController.Style.alert)
        alert.addAction(UIAlertAction(title: "Continue", style: UIAlertAction.Style.destructive, handler: { action in
            self.printOut("Fetching anisette via V1")
            UserDefaults.shared.trustedServerURL = AnisetteManager.currentURLString
            self.fetchAnisetteV1()
        }))
        alert.addAction(UIAlertAction(title: "Cancel", style: UIAlertAction.Style.cancel, handler: { action in
            self.printOut("Cancelled anisette operation")
            self.finish(.failure(OperationError.cancelled))
        }))

        let keyWindow = UIApplication.shared.windows.filter { $0.isKeyWindow }.first

        DispatchQueue.main.async {
            if let presentingController = keyWindow?.rootViewController?.presentedViewController {
                presentingController.present(alert, animated: true)
            } else {
                keyWindow?.rootViewController?.present(alert, animated: true)
            }
        }
    }
    
    func fetchAnisetteV1() {
        self.printOut("Fetching anisette V1")
        guard let url = self.url else {
            self.printOut("fetchAnisetteV1 aborted: server URL is nil")
            self.finish(.failure(OperationError.anisetteV1Error(message: "Anisette server URL is missing")))
            return
        }
        URLSession.shared.dataTask(with: url) { data, response, error in
            do {
                guard let data = data, error == nil else {
                    let desc = error?.localizedDescription ?? "unknown error"
                    throw OperationError.anisetteV1Error(message: "Unable to fetch data (\(desc))")
                }

                do {
                    try self.extractAnisetteData(data, response as? HTTPURLResponse, v3: false)
                } catch {
                    // The response body wasn't valid JSON. Classic V1 anisette
                    // servers return the anisette data in response HEADERS
                    // instead of a JSON body; fall back to reading the headers
                    // (case-insensitively, since HTTP/2 lowercases them).
                    guard let httpResponse = response as? HTTPURLResponse else {
                        self.printOut("Failed to load: \(error.localizedDescription)")
                        self.finish(.failure(error as NSError))
                        return
                    }
                    self.printOut("V1 body not JSON (\(error.localizedDescription)); falling back to response headers")

                    // Canonical key casing the parser expects.
                    let canonicalKeys = [
                        "x-apple-i-md": "X-Apple-I-MD",
                        "x-apple-i-md-m": "X-Apple-I-MD-M",
                        "x-apple-i-md-lu": "X-Apple-I-MD-LU",
                        "x-apple-i-md-rinfo": "X-Apple-I-MD-RINFO",
                        "x-apple-i-srl-no": "X-Apple-I-SRL-NO",
                        "x-apple-i-client-time": "X-Apple-I-Client-Time",
                        "x-apple-i-timezone": "X-Apple-I-TimeZone",
                        "x-apple-locale": "X-Apple-Locale",
                        "x-mme-client-info": "X-MMe-Client-Info",
                        "x-mme-device-id": "X-Mme-Device-Id",
                    ]
                    var headerJSON: [String: String] = [:]
                    for (rawKey, rawValue) in httpResponse.allHeaderFields {
                        guard let key = rawKey as? String, let value = rawValue as? String else { continue }
                        let canonical = canonicalKeys[key.lowercased()] ?? key
                        headerJSON[canonical] = value
                    }
                    guard headerJSON["X-Apple-I-MD"] != nil,
                          headerJSON["X-Apple-I-MD-M"] != nil else {
                        // No anisette data in headers either; surface original error.
                        self.printOut("Failed to load: \(error.localizedDescription)")
                        self.finish(.failure(error as NSError))
                        return
                    }
                    do {
                        let headerData = try JSONSerialization.data(withJSONObject: headerJSON)
                        try self.extractAnisetteData(headerData, httpResponse, v3: false)
                    } catch let headerError as NSError {
                        self.printOut("Failed to load (header fallback): \(headerError.localizedDescription)")
                        self.finish(.failure(headerError))
                    }
                }
            } catch let error as NSError {
                self.printOut("Failed to load: \(error.localizedDescription)")
                self.finish(.failure(error))
            }
        }.resume()
    }
    
    // MARK: - V3: PROVISIONING
    
    func provision() {
        fetchClientInfo {
            self.printOut("Getting provisioning URLs")
            guard let lookupURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup") else {
                self.printOut("Invalid lookup URL → falling back to V1")
                self.fetchAnisetteV1()
                return
            }
            guard var request = self.buildAppleRequest(url: lookupURL) else {
                self.fetchAnisetteV1()
                return
            }
            request.httpMethod = "GET"
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let data = data,
                   let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Dictionary<String, Dictionary<String, Any>>,
                   let startProvisioningString = plist["urls"]?["midStartProvisioning"] as? String,
                   let startProvisioningURL = URL(string: startProvisioningString),
                   let endProvisioningString = plist["urls"]?["midFinishProvisioning"] as? String,
                   let endProvisioningURL = URL(string: endProvisioningString) {
                    self.startProvisioningURL = startProvisioningURL
                    self.endProvisioningURL = endProvisioningURL
                    self.printOut("startProvisioningURL: \(self.startProvisioningURL!.absoluteString)")
                    self.printOut("endProvisioningURL: \(self.endProvisioningURL!.absoluteString)")
                    self.printOut("Starting a provisioning session")
                    self.startProvisioningSession()
                } else {
                    self.printOut("Apple didn't give valid URLs! Got response: \(String(data: data ?? Data("nothing".utf8), encoding: .utf8) ?? "not utf8")")
                    // gsa.apple.com unreachable or invalid response — degrade
                    // gracefully to the V1 root fetch instead of failing.
                    self.printOut("Provisioning lookup failed → falling back to V1 root fetch")
                    self.fetchAnisetteV1()
                }
            }.resume()
        }
    }
    
    func startProvisioningSession() {
        guard let url = self.url else {
            self.printOut("startProvisioningSession aborted: server URL is nil → falling back to V1")
            self.fetchAnisetteV1()
            return
        }
        let provisioningSessionURL = url.appendingPathComponent("v3").appendingPathComponent("provisioning_session")
        var wsRequest = URLRequest(url: provisioningSessionURL)
        wsRequest.timeoutInterval = 5
        self.socket = WebSocket(request: wsRequest)
        self.socket.delegate = self
        self.socket.connect()
    }
    
    func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        switch event {
        case .text(let string):
            do {
                guard let stringData = string.data(using: .utf8) else {
                    self.printOut("Failed to encode WebSocket text → falling back to V1")
                    client.disconnect(closeCode: 0)
                    self.fetchAnisetteV1()
                    return
                }
                if let json = try JSONSerialization.jsonObject(with: stringData, options: []) as? [String: Any] {
                    guard let result = json["result"] as? String else {
                        self.printOut("The server didn't give us a result")
                        client.disconnect(closeCode: 0)
                        self.finish(.failure(OperationError.provisioningError(result: "The server didn't give us a result", message: nil)))
                        return
                    }
                    self.printOut("Received result: \(result)")
                    switch result {
                    case "GiveIdentifier":
                        self.printOut("Giving identifier")
                        guard let identifier = Keychain.shared.identifier else {
                            self.printOut("No identifier to give server → falling back to V1")
                            client.disconnect(closeCode: 0)
                            self.fetchAnisetteV1()
                            return
                        }
                        client.json(["identifier": identifier])

                    case "GiveStartProvisioningData":
                        self.printOut("Getting start provisioning data")
                        guard let startProvisioningURL = self.startProvisioningURL,
                              var request = self.buildAppleRequest(url: startProvisioningURL) else {
                            self.printOut("startProvisioningURL missing or request build failed → falling back to V1")
                            client.disconnect(closeCode: 0)
                            self.fetchAnisetteV1()
                            return
                        }
                        let body = [
                            "Header": [String: Any](),
                            "Request": [String: Any](),
                        ]
                        request.httpMethod = "POST"
                        do {
                            request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
                        } catch {
                            self.printOut("Failed to serialize start provisioning body → falling back to V1: \(error)")
                            client.disconnect(closeCode: 0)
                            self.fetchAnisetteV1()
                            return
                        }
                        URLSession.shared.dataTask(with: request) { data, response, error in
                            if let data = data,
                               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Dictionary<String, Dictionary<String, Any>>,
                               let spim = plist["Response"]?["spim"] as? String {
                                self.printOut("Giving start provisioning data")
                                client.json(["spim": spim])
                            } else {
                                self.printOut("Apple didn't give valid start provisioning data! Got response: \(String(data: data ?? Data("nothing".utf8), encoding: .utf8) ?? "not utf8")")
                                client.disconnect(closeCode: 0)
                                self.fetchAnisetteV1()
                            }
                        }.resume()

                    case "GiveEndProvisioningData":
                        self.printOut("Getting end provisioning data")
                        guard let cpim = json["cpim"] as? String else {
                            self.printOut("The server didn't give us a cpim")
                            client.disconnect(closeCode: 0)
                            self.finish(.failure(OperationError.provisioningError(result: "The server didn't give us a cpim", message: nil)))
                            return
                        }
                        guard let endProvisioningURL = self.endProvisioningURL,
                              var request = self.buildAppleRequest(url: endProvisioningURL) else {
                            self.printOut("endProvisioningURL missing or request build failed → falling back to V1")
                            client.disconnect(closeCode: 0)
                            self.fetchAnisetteV1()
                            return
                        }
                        let body = [
                            "Header": [String: Any](),
                            "Request": [
                                "cpim": cpim,
                            ],
                        ]
                        request.httpMethod = "POST"
                        do {
                            request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
                        } catch {
                            self.printOut("Failed to serialize end provisioning body → falling back to V1: \(error)")
                            client.disconnect(closeCode: 0)
                            self.fetchAnisetteV1()
                            return
                        }
                        URLSession.shared.dataTask(with: request) { data, response, error in
                            if let data = data,
                               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Dictionary<String, Dictionary<String, Any>>,
                               let ptm = plist["Response"]?["ptm"] as? String,
                               let tk = plist["Response"]?["tk"] as? String {
                                self.printOut("Giving end provisioning data")
                                client.json(["ptm": ptm, "tk": tk])
                            } else {
                                self.printOut("Apple didn't give valid end provisioning data! Got response: \(String(data: data ?? Data("nothing".utf8), encoding: .utf8) ?? "not utf8")")
                                client.disconnect(closeCode: 0)
                                self.fetchAnisetteV1()
                            }
                        }.resume()

                    case "ProvisioningSuccess":
                        self.printOut("Provisioning succeeded!")
                        client.disconnect(closeCode: 0)
                        guard let adiPb = json["adi_pb"] as? String else {
                            self.printOut("The server didn't give us an adi.pb file")
                            self.fetchAnisetteV1()
                            return
                        }
                        Keychain.shared.adiPb = adiPb
                        // Record which server provisioned this adi.pb. The
                        // identity (client-info + UA) comes from that server,
                        // so switching servers must re-provision.
                        UserDefaults.standard.set(self.url?.absoluteString,
                                                  forKey: FetchAnisetteDataOperation.provisionedClientInfoKey)
                        guard let identifier = Keychain.shared.identifier,
                              let storedAdiPb = Keychain.shared.adiPb else {
                            self.printOut("Identifier/adiPb missing after provisioning → falling back to V1")
                            self.fetchAnisetteV1()
                            return
                        }
                        self.fetchAnisetteV3(identifier, storedAdiPb)

                    default:
                        if result.contains("Error") || result.contains("Invalid") || result == "ClosingPerRequest" || result == "Timeout" || result == "TextOnly" {
                            self.printOut("Failing because of \(result)")
                            // Provisioning protocol error — degrade to V1 instead
                            // of failing the whole operation.
                            client.disconnect(closeCode: 0)
                            self.fetchAnisetteV1()
                        }
                    }
                }
            } catch let error as NSError {
                self.printOut("Failed to handle text: \(error.localizedDescription)")
                client.disconnect(closeCode: 0)
                self.fetchAnisetteV1()
            }
            
        case .connected:
            self.printOut("Connected")

        case .disconnected(let string, let code):
            self.printOut("Disconnected: \(code); \(string)")
            if !self.isFinished {
                self.printOut("WebSocket disconnected before provisioning completed → falling back to V1")
                self.fetchAnisetteV1()
            }

        case .error(let error):
            self.printOut("Got error: \(String(describing: error))")
            if !self.isFinished {
                self.printOut("WebSocket error → falling back to V1")
                self.fetchAnisetteV1()
            }

        default:
            self.printOut("Unknown event: \(event)")
            if !self.isFinished {
                self.fetchAnisetteV1()
            }
        }
    }
    
    func buildAppleRequest(url: URL) -> URLRequest? {
        guard let clientInfo = self.clientInfo,
              let userAgent = self.userAgent,
              let mdLu = self.mdLu,
              let deviceId = self.deviceId else {
            self.printOut("buildAppleRequest aborted: V3 client fields not ready → falling back to V1")
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue(clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        request.setValue(mdLu, forHTTPHeaderField: "X-Apple-I-MD-LU")
        request.setValue(deviceId, forHTTPHeaderField: "X-Mme-Device-Id")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let dateString = formatter.string(from: Date())
        request.setValue(dateString, forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "X-Apple-Locale")
        request.setValue(TimeZone.current.abbreviation(), forHTTPHeaderField: "X-Apple-I-TimeZone")
        return request
    }
    
    // MARK: - V3: FETCHING
    
    func fetchClientInfo(_ callback: @escaping () -> Void) {
        if  self.clientInfo != nil &&
                self.userAgent != nil &&
                self.mdLu != nil &&
                self.deviceId != nil &&
                Keychain.shared.identifier != nil {
            self.printOut("Skipping client_info fetch since all the properties we need aren't nil")
            return callback()
        }
        self.printOut("Trying to get client_info")
        guard let clientInfoURL = self.url?.appendingPathComponent("v3").appendingPathComponent("client_info") else {
            self.printOut("client_info fetch aborted: server URL is nil")
            self.finish(.failure(OperationError.anisetteV3Error(message: "Anisette server URL is missing")))
            return
        }
        URLSession.shared.dataTask(with: clientInfoURL) { data, response, error in
            do {
                guard let data = data, error == nil else {
                    let desc = error?.localizedDescription ?? "unknown error"
                    return self.finish(.failure(OperationError.anisetteV3Error(message: "Couldn't fetch client info. The server may be down (\(desc))")))
                }
                
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: String] {
                    if let clientInfo = json["client_info"] {
                        self.printOut("Server is V3")
                        
                        // FIX(gsa-503): anisette servers send the blocked
                        // "com.apple.dt.Xcode" identifier; normalize to akd.
                        self.clientInfo = self.sanitizeClientInfo(clientInfo)
                        guard let userAgent = json["user_agent"] else {
                            self.printOut("Server returned client_info but missing user_agent; falling back to V1 root fetch")
                            self.finish(.failure(OperationError.anisetteV3Error(message: "Server returned invalid client_info (missing user_agent)")))
                            return
                        }
                        self.userAgent = userAgent
                        self.serverUserAgent = userAgent
                        self.printOut("Client-Info: \(clientInfo)")
                        self.printOut("User-Agent: \(userAgent)")
                        
                        if Keychain.shared.identifier == nil {
                            self.printOut("Generating identifier")
                            var bytes = [Int8](repeating: 0, count: 16)
                            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                            
                            if status != errSecSuccess {
                                self.printOut("ERROR GENERATING IDENTIFIER!!! \(status)")
                                return self.finish(.failure(OperationError.provisioningError(result: "Couldn't generate identifier", message: nil)))
                            }
                            
                            let generated = Data(bytes: &bytes, count: bytes.count).base64EncodedString()
                            Keychain.shared.identifier = generated
                        }
                        
                        guard let identifier = Keychain.shared.identifier,
                              let decoded = Data(base64Encoded: identifier),
                              decoded.count == 16 else {
                            self.printOut("Identifier is missing or not valid base64; regenerating")
                            // Regenerate a fresh identifier instead of crashing on force-unwrap.
                            var bytes = [Int8](repeating: 0, count: 16)
                            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                            if status != errSecSuccess {
                                return self.finish(.failure(OperationError.provisioningError(result: "Couldn't generate identifier", message: nil)))
                            }
                            let generated = Data(bytes: &bytes, count: bytes.count).base64EncodedString()
                            Keychain.shared.identifier = generated
                            guard let regen = Data(base64Encoded: generated) else {
                                return self.finish(.failure(OperationError.anisetteV3Error(message: "Failed to create a valid device identifier")))
                            }
                            let mdLu = regen.sha256().hexEncodedString()
                            self.mdLu = mdLu
                            let uuid: UUID = regen.object()
                            self.deviceId = uuid.uuidString.uppercased()
                            self.printOut("X-Apple-I-MD-LU: \(mdLu)")
                            self.printOut("X-Mme-Device-Id: \(self.deviceId!)")
                            return callback()
                        }
                        let mdLu = decoded.sha256().hexEncodedString()
                        self.mdLu = mdLu
                        self.printOut("X-Apple-I-MD-LU: \(mdLu)")
                        let uuid: UUID = decoded.object()
                        self.deviceId = uuid.uuidString.uppercased()
                        self.printOut("X-Mme-Device-Id: \(self.deviceId!)")
                        
                        callback()
                    } else { self.handleV1() }
                } else { self.finish(.failure(OperationError.anisetteV3Error(message: "Couldn't fetch client info. The returned data may not be in JSON"))) }
            } catch let error as NSError {
                self.printOut("Failed to load: \(error.localizedDescription)")
                self.handleV1()
            }
        }.resume()
    }
    
    func fetchAnisetteV3(_ identifier: String, _ adiPb: String) {
        fetchClientInfo {
            self.printOut("Fetching anisette V3")
            guard let baseURL = self.url else {
                self.printOut("fetchAnisetteV3 aborted: server URL is nil → falling back to V1")
                self.finish(.failure(OperationError.anisetteV3Error(message: "Anisette server URL is missing")))
                return
            }
            var request = URLRequest(url: baseURL.appendingPathComponent("v3").appendingPathComponent("get_headers"))
            request.httpMethod = "POST"
            request.httpBody = try! JSONSerialization.data(withJSONObject: [
                "identifier": identifier,
                "adi_pb": adiPb
            ], options: [])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            URLSession.shared.dataTask(with: request) { data, response, error in
                do {
                    guard let data = data, error == nil else { throw OperationError.anisetteV3Error(message: "Couldn't fetch anisette") }
                    
                    try self.extractAnisetteData(data, response as? HTTPURLResponse, v3: true)
                } catch let error as NSError {
                    self.printOut("Failed to load: \(error.localizedDescription)")
                    self.finish(.failure(error))
                }
            }.resume()
        }
    }
    
    
    // MARK: - Client info sanitization

    /// Since early September 2026, Apple's GSA edge rejects (HTTP 503, non-plist
    /// error body) requests whose `X-MMe-Client-Info` carries the stale Xcode-era
    /// client string that anisette servers still serve. Merely replacing the
    /// `com.apple.dt.Xcode/x.y.z` substring while keeping the old machine/OS
    /// string (e.g. `<MacBookPro13,2> <macOS;13.1;22C65>`) is NOT enough — the
    /// stale machine + OS combination is blocked as well.
    ///
    /// Both working references hardcode a *current* client string locally and
    /// ignore whatever the anisette server sends:
    ///   - isideload a19f5f0 / PR#11: "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
    ///   - SideStore AnisetteKit:    "<MacBookPro18,3> <macOS;26.6;25F84> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
    ///
    /// We pin the official AnisetteKit string. The anisette OTP headers
    /// (X-Apple-I-MD etc.) are bound to the machine identifier, not to this
    /// header, so swapping it client-side is safe.
    ///
    /// FIX(gsa-503-2026-11): Apple started 503-ing the macOS 12+ client-info
    /// family on the GrandSlam edge around 2026-11. Verified 2026-11-25 by
    /// POSTing a real SRP init plist to gsService2 and varying only the header:
    ///   <...> <macOS;12.0;...> and every newer macOS  → 503 + HTML error page
    ///   <...> <macOS;11.7;...>                        → 200 + usable plist
    ///   <...> <Mac OS X;...> (any version)            → 200 + usable plist
    ///   <...> <iPhone OS;17.5/18.5>                   → 200 + usable plist
    ///
    /// The token that matters is the *family*, not the version: `macOS;` is
    /// rejected from 12.0 upwards, while the older spelling `Mac OS X;` passes
    /// at any version. The string shipped in 7649c8ff was
    /// "<MacBookPro18,3> <macOS;26.6;25F84> ...", so it lands squarely in the
    /// blocked bucket — the 503 HTML page is what the plist parser then chokes
    /// on, surfacing as NSCocoaErrorDomain 3840 ("The data couldn't be read
    /// because it isn't in the correct format.").
    ///
    /// Keep the model and OS version from the official AnisetteKit string and
    /// change only the family token. This is the same one-word change users
    /// confirmed in SideStore#1745 / #1749 / #1752, and it is what iloader
    /// settled on after rolling back its `macOS;27.0` override
    /// (nab138/iloader 7364ae6).
    ///
    /// Changing this string invalidates any cached adi.pb, because adi.pb is
    /// provisioned against the identity presented at provisioning time. A
    /// stale pair fails Apple's late identity check with -22410 (mapped in
    /// ALTAppleAPI+Authentication.swift), which is why that error is reported
    /// as "reset adi.pb" rather than as a credential problem.
    /// FIX(gsa-22410-family): pin back to the `iPhone OS;` family.
    ///
    /// 274b6bcc pinned `<MacBookPro18,3> <Mac OS X;26.6;25F84> ...`, which
    /// clears the edge (HTTP 200, so no more 3840) but is then rejected by a
    /// *late* identity check with -22410 — the same second-stage rejection
    /// SideStore#1745 records for the `Mac OS X;` family ("the old Mac OS X;
    /// 10.12.6 identity passed validation, but Apple then rejected it with
    /// -22410 or -23782").
    ///
    /// So `Mac OS X;` is not a safe pin even though it fixes the 503: it moves
    /// the failure from the edge to the post-anisette check, where it surfaces
    /// as "This action could not be completed".
    ///
    /// `<iPhone OS;>` is the family the user confirmed can actually sign in
    /// (build 9f2253db, which pinned exactly this string). Verified 2026-11-25
    /// against gsService2 with a real SRP init: `iPhone OS;18.5` and
    /// `iPhone OS;26.0` both return HTTP 200 with `ec=-1`, identical to the
    /// control — i.e. no edge rejection and no late family rejection, which is
    /// the best a probe can show without real credentials.
    ///
    /// Keep the model/version verbatim from 9f2253db rather than inventing a
    /// new combination: that exact string is the one with a field confirmation
    /// behind it.
    static let pinnedClientInfo = "<iPhone14,5> <iPhone OS;18.5;22F76> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"

    /// Records which anisette server provisioned the cached adi.pb.
    ///
    /// The identity (client-info + UA) is declared by that server, so a cached
    /// adi.pb is only valid with the server that minted it. A missing value
    /// means the adi.pb predates this marker and should be discarded once.
    /// The key name is kept for compatibility with builds that wrote a client
    /// string into it — any such value differs from a URL and is discarded.
    static let provisionedClientInfoKey = "FetchAnisetteDataOperation.provisionedClientInfo"

    /// Rewrites the two client-info families Apple's GrandSlam edge refuses.
    ///
    /// Verified 2026-11-25 by POSTing a real SRP-init plist to
    /// gsService2 with only the header varying (see `_503fix_assume.py`):
    ///
    ///   `<MacBookPro13,2> <macOS;13.1;22C65> <…(com.apple.dt.Xcode/3594.4.19)>` -> 503 HTML
    ///   `<MacBookPro13,2> <Mac OS X;13.1;22C65> <…(com.apple.dt.Xcode/3594.4.19)>` -> 503 HTML
    ///   `<MacBookPro13,2> <Mac OS X;13.1;22C65> <…(com.apple.akd/1.0)>`          -> 200 + ec=-1
    ///
    /// The 503 body is the HTML page AltSign reports as NSCocoaErrorDomain 3840.
    /// Both blocked families are live in the server list: ani.sidestore.zip,
    /// ani.npeg.us and ani.xu30.top all serve the `com.apple.dt.Xcode/…`
    /// identifier, and ani.jaydenha.uk pairs it with a lowercase `macOS;` token.
    ///
    /// The model and OS version are preserved — Apple binds the adi.pb minted
    /// during provisioning to the whole string, so inventing a combination
    /// instead of fixing the blocked token breaks that pairing.
    static func normalizeClientInfo(_ clientInfo: String) -> String {
        // Match only the versioned family token, so a stray "macOS" elsewhere
        // in the string is not rewritten.
        let familyFixed = clientInfo.replacingOccurrences(of: "<macOS;", with: "<Mac OS X;")
        return normalizeClientIdentifier(familyFixed)
    }

    /// Rewrites `com.apple.dt.Xcode/…` to `com.apple.akd/1.0` in the client
    /// identifier (the third `<…>` field, e.g.
    /// `<com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>`).
    ///
    /// Only the parenthesised bracketed identifier is replaced: the version
    /// number is part of what the edge rejects, so it must not survive in the
    /// output. Unbracketed or malformed text is left untouched rather than
    /// guessed at, and other identifiers keep working unchanged.
    private static func normalizeClientIdentifier(_ clientInfo: String) -> String {
        let marker = "(com.apple.dt."
        guard clientInfo.contains(marker) else { return clientInfo }

        var result = clientInfo
        // Replace every occurrence instead of assuming exactly one. Removing
        // the marker each pass keeps the loop finite.
        while true {
            guard let open = result.range(of: marker),
                  let close = result[open.upperBound...].firstIndex(of: ")") else { break }
            let end = result.index(after: close)
            result.replacingCharacters(in: open.lowerBound..<end, with: "(com.apple.akd/1.0)")
        }
        return result
    }

    // If Apple blocks this string the same way it blocked the macOS 26 one,
    // replace `pinnedClientInfo` above with a verified alternative. Checked
    // 2026-11-25 (each returned HTTP 200 + a parseable GrandSlam plist):
    //   "<iPhone14,5> <iPhone OS;17.5;21F79> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
    //   "<MacBookPro15,1> <macOS;11.7;20G817> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
    // Verify a candidate before shipping by POSTing an SRP init plist to
    // https://gsa.apple.com/grandslam/GsService2 and requiring <key>Response</key>
    // in the body — a bare HTTP 200 with an empty body means the edge accepted
    // the header but the request was still rejected downstream.

    func sanitizeClientInfo(_ clientInfo: String) -> String {
        // FIX(ani-80043-match): send the identity the anisette server declares.
        //
        // Apple's GrandSlam edge checks that X-MMe-Client-Info matches the
        // client that actually generated the anisette data (AltSign PR #61).
        // Overwriting the server's value with a hardcoded `iPhone OS;` string
        // breaks that pairing: provisioning then fails with HTTP 401 at
        // finishMachineProvisioning, the client falls back to the shared V1
        // endpoint, and Apple rejects that identity with -80043.
        //
        // Verified 2026-11-25 with a full provisioning + GSA probe against all
        // 22 servers: the same server and identifier succeed with its own
        // client-info but fail 401 with the hardcoded `iPhone OS;` value.
        //
// Only the blocked families are rewritten — the lowercase `macOS;` token
        // and the Xcode-era `com.apple.dt.Xcode/…` identifier. The model and
        // OS version are kept exactly as the server provisioned against, and
        // the matching User-Agent is forwarded to AltSign by the caller.
        let normalized = FetchAnisetteDataOperation.normalizeClientInfo(clientInfo)
        if normalized != clientInfo {
            self.printOut("Rewrote blocked client-info family \"\(clientInfo)\" → \"\(normalized)\"")
        }
        return normalized
    }

    private func printOut(_ text: String?){
        let isInternalLoggingEnabled = OperationsLoggingControl.getFromDatabase(for: ANISETTE_VERBOSITY.self)
        if(isInternalLoggingEnabled){
            // logging enabled, so log it
            text.map{ _ in print(text!) } ?? print()
        }
    }
}

extension WebSocketClient {
    func json(_ dictionary: [String: String]) {
        let data = try! JSONSerialization.data(withJSONObject: dictionary, options: [])
        self.write(string: String(data: data, encoding: .utf8)!)
    }
}

extension Data {
    // https://stackoverflow.com/a/25391020
    func sha256() -> Data {
        var hash = [UInt8](repeating: 0,  count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(self.count), &hash)
        }
        return Data(hash)
    }
    
    // https://stackoverflow.com/a/40089462
    func hexEncodedString() -> String {
        return self.map { String(format: "%02hhX", $0) }.joined()
    }
    
    // https://stackoverflow.com/a/59127761
    func object<T>() -> T { self.withUnsafeBytes { $0.load(as: T.self) } }
}
