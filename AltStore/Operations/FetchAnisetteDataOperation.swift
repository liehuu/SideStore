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
    
    var mdLu: String?
    var deviceId: String?

    // FIX(1100): consecutive V1 fetches may land on different load-balanced
    // virtual devices; count retries while trying to match the machineID
    // bound to the cached session token.
    private var v1MachineIDRetryCount = 0
    
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

            if let identifier = Keychain.shared.identifier,
               let adiPb = Keychain.shared.adiPb {
                self.fetchAnisetteV3(identifier, adiPb)
            } else {
                // FIX(login-crash): No cached adi.pb → do NOT enter the WebSocket V3
                // provisioning flow. That flow requires reaching gsa.apple.com
                // (https://gsa.apple.com/grandslam/GsService2/lookup), which is blocked or
                // unreachable in many regions and, combined with force-unwraps along the
                // provisioning path, caused sign-in to silently crash/exit.
                //
                // Official SideSign's RemoteAnisetteDataProvider does the same thing here:
                // when adiPb is empty it skips v3 get_headers and falls back to a plain
                // V1 root GET, which returns full anisette headers without any Apple
                // provisioning handshake. Align with that behavior.
                self.printOut("No cached adi.pb → using V1 root fetch (skipping gsa.apple.com + WebSocket provisioning)")
                self.fetchAnisetteV1()
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
        
        tryNextServer(from: serverUrls, viewContext, currentIndex: 0, completion: completion)
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
            var request = self.buildAppleRequest(url: URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!)
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
                    self.finish(.failure(OperationError.provisioningError(result: "Apple didn't give valid URLs. Please try again later", message: nil)))
                }
            }.resume()
        }
    }
    
    func startProvisioningSession() {
        let provisioningSessionURL = self.url!.appendingPathComponent("v3").appendingPathComponent("provisioning_session")
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
                if let json = try JSONSerialization.jsonObject(with: string.data(using: .utf8)!, options: []) as? [String: Any] {
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
                        client.json(["identifier": Keychain.shared.identifier!])
                        
                    case "GiveStartProvisioningData":
                        self.printOut("Getting start provisioning data")
                        let body = [
                            "Header": [String: Any](),
                            "Request": [String: Any](),
                        ]
                        var request = self.buildAppleRequest(url: self.startProvisioningURL!)
                        request.httpMethod = "POST"
                        request.httpBody = try! PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
                        URLSession.shared.dataTask(with: request) { data, response, error in
                            if let data = data,
                               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Dictionary<String, Dictionary<String, Any>>,
                               let spim = plist["Response"]?["spim"] as? String {
                                self.printOut("Giving start provisioning data")
                                client.json(["spim": spim])
                            } else {
                                self.printOut("Apple didn't give valid start provisioning data! Got response: \(String(data: data ?? Data("nothing".utf8), encoding: .utf8) ?? "not utf8")")
                                client.disconnect(closeCode: 0)
                                self.finish(.failure(OperationError.provisioningError(result: "Apple didn't give valid start provisioning data. Please try again later", message: nil)))
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
                        let body = [
                            "Header": [String: Any](),
                            "Request": [
                                "cpim": cpim,
                            ],
                        ]
                        var request = self.buildAppleRequest(url: self.endProvisioningURL!)
                        request.httpMethod = "POST"
                        request.httpBody = try! PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
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
                                self.finish(.failure(OperationError.provisioningError(result: "Apple didn't give valid end provisioning data. Please try again later", message: nil)))
                            }
                        }.resume()
                        
                    case "ProvisioningSuccess":
                        self.printOut("Provisioning succeeded!")
                        client.disconnect(closeCode: 0)
                        guard let adiPb = json["adi_pb"] as? String else {
                            self.printOut("The server didn't give us an adi.pb file")
                            self.finish(.failure(OperationError.provisioningError(result: "The server didn't give us an adi.pb file", message: nil)))
                            return
                        }
                        Keychain.shared.adiPb = adiPb
                        self.fetchAnisetteV3(Keychain.shared.identifier!, Keychain.shared.adiPb!)
                        
                    default:
                        if result.contains("Error") || result.contains("Invalid") || result == "ClosingPerRequest" || result == "Timeout" || result == "TextOnly" {
                            self.printOut("Failing because of \(result)")
                            self.finish(.failure(OperationError.provisioningError(result: result, message: json["message"] as? String)))
                        }
                    }
                }
            } catch let error as NSError {
                self.printOut("Failed to handle text: \(error.localizedDescription)")
                self.finish(.failure(OperationError.provisioningError(result: error.localizedDescription, message: nil)))
            }
            
        case .connected:
            self.printOut("Connected")
            
        case .disconnected(let string, let code):
            self.printOut("Disconnected: \(code); \(string)")
            
        case .error(let error):
            self.printOut("Got error: \(String(describing: error))")
            
        default:
            self.printOut("Unknown event: \(event)")
        }
    }
    
    func buildAppleRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(self.clientInfo!, forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue(self.userAgent!, forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        request.setValue(self.mdLu!, forHTTPHeaderField: "X-Apple-I-MD-LU")
        request.setValue(self.deviceId!, forHTTPHeaderField: "X-Mme-Device-Id")

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
    static let pinnedClientInfo = "<MacBookPro18,3> <macOS;26.6;25F84> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"

    func sanitizeClientInfo(_ clientInfo: String) -> String {
        guard clientInfo != FetchAnisetteDataOperation.pinnedClientInfo else {
            return clientInfo
        }
        self.printOut("Replacing server client-info \"\(clientInfo)\" → pinned akd string (official AnisetteKit value)")
        return FetchAnisetteDataOperation.pinnedClientInfo
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
