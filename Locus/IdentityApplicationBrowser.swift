import AppKit
import Foundation
import WebKit

/// Native-only values. Never encode these snapshots into a browser tool result.
struct IdentityBrowserField: Identifiable, Equatable {
    let id: String
    let label: String
    let type: String
}

struct IdentityBrowserAction: Identifiable, Equatable {
    let id: String
    let label: String
    let type: String
}

struct IdentityBrowserSnapshot: Equatable {
    let sessionID: String
    let tabID: String
    let origin: String
    let navigationID: String
    let text: String
    let fields: [IdentityBrowserField]
    let actions: [IdentityBrowserAction]
}

struct IdentityBrowserBinding: Equatable {
    let fieldID: String
    let value: String
}

enum IdentityBrowserError: LocalizedError, Equatable {
    case unavailable, invalidURL, changed, unsupported, cancelled, uploadFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: "The private application page is unavailable."
        case .invalidURL: "Open an HTTPS application page, or a local test page."
        case .changed: "The application page changed. Review it again before sharing."
        case .unsupported: "This application control cannot be filled safely."
        case .cancelled: "The private application action was cancelled."
        case .uploadFailed: "The approved document could not be attached."
        }
    }
}

/// Even a generic inspector preference setter cannot enable debugging for a
/// protected web view after it has been constructed.
@MainActor
final class IdentityApplicationWebView: WKWebView {
    override var isInspectable: Bool {
        get { false }
        set { super.isInspectable = false }
    }
}

/// Each application owns a fresh in-memory WebKit store. Popups and new tabs
/// share only that application's store, never the ordinary browser profile.
@MainActor
final class IdentityApplicationSession {
    let dataStore = WKWebsiteDataStore.nonPersistent()

    static func permits(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.host != nil else { return false }
        return url.scheme?.lowercased() == "https"
            || (url.scheme?.lowercased() == "http" && BrowserScheme.isLoopback(url))
    }

    func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.userContentController.addUserScript(IdentityApplicationPage.script())
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.applicationNameForUserAgent = "Version/17.4 Safari/605.1.15"
        return configuration
    }
}

/// Separate delegates are deliberate: no normal capture, Autofill, history,
/// download, wallet, favicon, dialog, or raw-error path sees a private page.
@MainActor
final class IdentityApplicationPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let world = WKContentWorld.world(name: "locus.identity.application")
    private weak var webView: WKWebView?
    private let sessionID: String
    private let tabID: String
    private var generation = UUID().uuidString
    private var cancellationGeneration = 0
    private var currentSnapshot: IdentityBrowserSnapshot?
    private var scriptToken: String?
    private var documentURL: String?
    private var closed = false
    private var upload: PendingUpload?
    var onChange: (() -> Void)?
    var onPopup: ((WKWebViewConfiguration) -> WKWebView?)?
    var onClose: (() -> Void)?

    private struct PendingUpload {
        let url: URL
        let snapshot: IdentityBrowserSnapshot
        let fieldID: String
        var consumed = false
    }

    init(webView: WKWebView, sessionID: String, tabID: String) {
        self.webView = webView
        self.sessionID = sessionID
        self.tabID = tabID
    }

    func close() {
        closed = true
        cancelPendingActions()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        onChange = nil
        onPopup = nil
        onClose = nil
    }

    /// Revoke native approvals before stopping WebKit. In particular, an
    /// outstanding file-picker callback must never receive bytes after Stop.
    func cancelPendingActions() {
        cancellationGeneration += 1
        invalidate()
        webView?.evaluateJavaScript(
            "globalThis.__locusIdentity?.cancel()",
            in: nil, in: Self.world, completionHandler: nil
        )
    }

    private func invalidate() {
        generation = UUID().uuidString
        currentSnapshot = nil
        scriptToken = nil
        documentURL = nil
        if let upload { try? FileManager.default.removeItem(at: upload.url.deletingLastPathComponent()) }
        upload = nil
    }

    func snapshot() async throws -> IdentityBrowserSnapshot {
        guard !closed, let webView, !webView.isLoading,
              let url = webView.url, IdentityApplicationSession.permits(url)
        else { throw IdentityBrowserError.unavailable }
        let startedGeneration = generation
        let raw = try await invoke("snapshot", arguments: [:])
        guard startedGeneration == generation, !closed,
              let token = raw["token"] as? String,
              let href = raw["href"] as? String,
              href == webView.url?.absoluteString,
              let origin = raw["origin"] as? String,
              let text = raw["text"] as? String,
              raw["complete"] as? Bool == true
        else { throw IdentityBrowserError.changed }
        let fields = (raw["fields"] as? [[String: String]] ?? []).compactMap { field -> IdentityBrowserField? in
            guard let id = field["id"], let label = field["label"], let type = field["type"] else { return nil }
            return IdentityBrowserField(id: id, label: label, type: type)
        }
        let actions = (raw["actions"] as? [[String: String]] ?? []).compactMap { action -> IdentityBrowserAction? in
            guard let id = action["id"], let label = action["label"], let type = action["type"] else { return nil }
            return IdentityBrowserAction(id: id, label: label, type: type)
        }
        let result = IdentityBrowserSnapshot(
            sessionID: sessionID, tabID: tabID, origin: origin,
            navigationID: UUID().uuidString, text: text, fields: fields, actions: actions
        )
        scriptToken = token
        documentURL = href
        currentSnapshot = result
        return result
    }

    func fill(snapshot: IdentityBrowserSnapshot, bindings: [IdentityBrowserBinding]) async throws -> String {
        guard !bindings.isEmpty, bindings.count <= 100,
              Set(bindings.map(\.fieldID)).count == bindings.count,
              bindings.allSatisfy({ binding in
                  binding.value.utf8.count <= 100_000
                      && snapshot.fields.contains { $0.id == binding.fieldID && $0.type != "file" }
              })
        else { throw IdentityBrowserError.unsupported }
        let arguments = try validatedArguments(snapshot)
        let raw = try await invoke("fill", arguments: arguments.merging([
            "bindings": bindings.map { ["id": $0.fieldID, "value": $0.value] },
        ]) { _, new in new })
        currentSnapshot = nil
        guard raw["ok"] as? Bool == true else { throw IdentityBrowserError.changed }
        return "Approved fields filled locally."
    }

    func click(snapshot: IdentityBrowserSnapshot, actionID: String) async throws -> String {
        guard snapshot.actions.contains(where: { $0.id == actionID }) else {
            throw IdentityBrowserError.unsupported
        }
        let arguments = try validatedArguments(snapshot)
        let raw = try await invoke("click", arguments: arguments.merging(["id": actionID]) { _, new in new })
        currentSnapshot = nil
        guard raw["ok"] as? Bool == true else { throw IdentityBrowserError.changed }
        return "Approved application action performed."
    }

    /// The sole private file-picker exception. A one-shot, main-frame grant
    /// supplies exactly the approved bytes; the page never chooses a path.
    func attach(snapshot: IdentityBrowserSnapshot, fieldID: String, data: Data, filename: String) async throws -> String {
        let startedCancellation = cancellationGeneration
        guard data.count > 0, data.count <= 25_000_000,
              snapshot.fields.contains(where: { $0.id == fieldID && $0.type == "file" }),
              upload == nil else { throw IdentityBrowserError.unsupported }
        let arguments = try validatedArguments(snapshot)
        let cleanName = URL(fileURLWithPath: filename).lastPathComponent
        guard !cleanName.isEmpty, cleanName != ".", cleanName != "..", cleanName.utf8.count <= 240 else {
            throw IdentityBrowserError.unsupported
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Locus-Identity-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent(cleanName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw IdentityBrowserError.uploadFailed
        }
        upload = PendingUpload(url: file, snapshot: snapshot, fieldID: fieldID)
        defer {
            upload = nil
            currentSnapshot = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let raw = try await invoke("upload", arguments: arguments.merging(["id": fieldID]) { _, new in new })
        guard raw["ok"] as? Bool == true else { throw IdentityBrowserError.changed }
        for _ in 0..<100 {
            guard !closed, !Task.isCancelled, startedCancellation == cancellationGeneration else {
                throw IdentityBrowserError.cancelled
            }
            guard upload != nil else { throw IdentityBrowserError.changed }
            if upload?.consumed == true {
                let copied = try await invoke("finishUpload", arguments: ["id": fieldID, "size": data.count, "name": cleanName])
                if copied["ok"] as? Bool == true { return "Approved document attached locally." }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw IdentityBrowserError.uploadFailed
    }

    private func validatedArguments(_ snapshot: IdentityBrowserSnapshot) throws -> [String: Any] {
        guard !closed, currentSnapshot == snapshot,
              snapshot.sessionID == sessionID, snapshot.tabID == tabID,
              let token = scriptToken, let href = documentURL,
              webView?.url?.absoluteString == href, webView?.isLoading == false
        else { throw IdentityBrowserError.changed }
        return ["token": token, "href": href]
    }

    private func invoke(_ method: String, arguments: [String: Any]) async throws -> [String: Any] {
        let startedCancellation = cancellationGeneration
        guard !Task.isCancelled else { throw IdentityBrowserError.cancelled }
        guard !closed, let webView else { throw IdentityBrowserError.unavailable }
        do {
            let result = try await webView.callAsyncJavaScript(
                "return await globalThis.__locusIdentity[method](args);",
                arguments: ["method": method, "args": arguments], in: nil, contentWorld: Self.world
            )
            guard startedCancellation == cancellationGeneration, !Task.isCancelled else {
                throw IdentityBrowserError.cancelled
            }
            guard !closed, let dictionary = result as? [String: Any] else {
                throw IdentityBrowserError.unavailable
            }
            return dictionary
        } catch {
            guard startedCancellation == cancellationGeneration, !Task.isCancelled else {
                throw IdentityBrowserError.cancelled
            }
            throw (error as? IdentityBrowserError) ?? IdentityBrowserError.unavailable
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { invalidate(); onChange?() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onChange?() }
    func webView(_ webView: WKWebView, didSameDocumentNavigation navigation: WKNavigation!) { invalidate(); onChange?() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { invalidate(); onChange?() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { invalidate(); onChange?() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { invalidate(); onChange?() }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard !closed, let url = navigationAction.request.url else { decisionHandler(.cancel, preferences); return }
        // Subframes inherit the same private store/delegates but cannot receive
        // native fields. External-app handoffs and file/data/blob navigation
        // never leave this private context.
        let allowed = IdentityApplicationSession.permits(url) || url.absoluteString == "about:blank"
        decisionHandler(allowed ? .allow : .cancel, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !closed, let url = navigationAction.request.url,
              IdentityApplicationSession.permits(url) || url.absoluteString == "about:blank"
        else { return nil }
        return onPopup?(configuration)
    }

    func webViewDidClose(_ webView: WKWebView) { onClose?() }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard !closed, frame.isMainFrame, !parameters.allowsDirectories,
              var pending = upload, !pending.consumed,
              (try? validatedArguments(pending.snapshot)) != nil else {
            completionHandler(nil); return
        }
        // Re-check the focused DOM control in the isolated world before the
        // delegate supplies bytes. A page cannot redirect the armed chooser.
        Task { @MainActor [weak self] in
            guard let self else { completionHandler(nil); return }
            let raw = try? await invoke("validateUpload", arguments: ["id": pending.fieldID])
            guard raw?["ok"] as? Bool == true,
                  (try? validatedArguments(pending.snapshot)) != nil,
                  upload?.consumed == false else { completionHandler(nil); return }
            pending.consumed = true
            upload = pending
            completionHandler([pending.url])
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

    static func script() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
    }

    private static let source = #"""
    (() => {
      if (globalThis.__locusIdentity) return;
      const documentID = crypto.randomUUID();
      let revision = 0, serial = 0, records = new Map(), uploading = null;
      const observer = new MutationObserver(() => { revision++; });
      observer.observe(document, {subtree:true, childList:true, attributes:true, characterData:true});
      const sync = () => { if (observer.takeRecords().length) revision++; };
      const token = () => documentID + ':' + revision;
      const visible = el => {
        if (!el.isConnected || el.disabled || el.readOnly || el.closest('[inert]')) return false;
        const r = el.getBoundingClientRect(), s = getComputedStyle(el);
        return r.width > 0 && r.height > 0 && s.display !== 'none' && s.visibility !== 'hidden' && s.opacity !== '0';
      };
      const label = el => (el.getAttribute('aria-label') ||
        Array.from(el.labels || []).map(x => x.innerText).join(' ') ||
        el.getAttribute('placeholder') || el.innerText || el.name || el.id || el.type || el.tagName).trim();
      const type = el => el.tagName === 'TEXTAREA' ? 'textarea' : el.tagName === 'SELECT' ? 'select' : (el.type || el.tagName.toLowerCase());
      const fingerprint = el => JSON.stringify([label(el), type(el), el.name, el.id,
        el.getAttribute('autocomplete'), el.getAttribute('href'), el.getAttribute('formaction'),
        el.form?.action, el.form?.method, el.getAttribute('accept'), el.multiple,
        el.tagName === 'SELECT' ? Array.from(el.options).map(o => [o.value, o.text, o.disabled]) : null]);
      const record = (el, kind) => {
        const id = 'identity_' + (++serial);
        records.set(id, {el,kind,fingerprint:fingerprint(el)});
        return {id,label:label(el),type:kind === 'action' ? (el.tagName === 'A' ? 'link' : type(el)) : type(el)};
      };
      const get = (id, kind) => {
        const r = records.get(id);
        return r && r.kind === kind && visible(r.el) && r.el.ownerDocument === document &&
          fingerprint(r.el) === r.fingerprint ? r.el : null;
      };
      const valid = args => { sync(); return args.token === token() && args.href === location.href; };
      const unsupported = new Set(['hidden','password','submit','button','reset','image','range','color']);
      globalThis.__locusIdentity = {
        cancel() { revision++; records = new Map(); uploading = null; },
        snapshot() {
          sync(); records = new Map();
          const candidates = Array.from(document.querySelectorAll('input,textarea,select'))
            .filter(el => visible(el) && !unsupported.has(type(el)));
          const buttons = Array.from(document.querySelectorAll('button,a[href],input[type="submit"],input[type="button"]'))
            .filter(visible);
          const text = document.body?.innerText || '';
          const complete = text.length <= 150000 && candidates.length <= 200 && buttons.length <= 200 &&
            [...candidates,...buttons].every(el => label(el).length <= 1000);
          const fields = candidates.slice(0,200).map(el => record(el,'field'));
          const actions = buttons.slice(0,200).map(el => record(el,'action'));
          sync();
          return {token:token(),href:location.href,origin:location.origin,text:text.slice(0,150000),fields,actions,complete};
        },
        fill(args) {
          if (!valid(args)) return {ok:false};
          const targets = args.bindings.map(b => ({...b,el:get(b.id,'field')}));
          for (const t of targets) {
            if (t.el && type(t.el) === 'select') {
              const choices = Array.from(t.el.options).filter(o => !o.disabled &&
                (o.value === t.value || o.text.trim() === t.value));
              if (choices.length !== 1) return {ok:false};
              t.value = choices[0].value;
            }
          }
          if (targets.some(t => !t.el || type(t.el) === 'file' ||
            (['checkbox','radio'].includes(type(t.el)) && !['true','false'].includes(t.value)))) return {ok:false};
          // Set every value before dispatching events, because React and other
          // form libraries may replace controls synchronously on the first event.
          for (const t of targets) {
            const prop = ['checkbox','radio'].includes(type(t.el)) ? 'checked' : 'value';
            const proto = t.el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype :
              t.el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
            Object.getOwnPropertyDescriptor(proto,prop).set.call(t.el, prop === 'checked' ? t.value === 'true' : t.value);
          }
          for (const t of targets) {
            t.el.dispatchEvent(new Event('input',{bubbles:true}));
            t.el.dispatchEvent(new Event('change',{bubbles:true}));
          }
          revision++;
          return {ok:true};
        },
        click(args) {
          if (!valid(args)) return {ok:false};
          const el = get(args.id,'action'); if (!el) return {ok:false};
          revision++; el.click(); return {ok:true};
        },
        upload(args) {
          if (!valid(args)) return {ok:false};
          const el = get(args.id,'field'); if (!el || type(el) !== 'file') return {ok:false};
          uploading = {id:args.id,el}; el.focus(); el.click(); return {ok:true};
        },
        validateUpload(args) {
          return {ok:uploading?.id === args.id && uploading.el === get(args.id,'field') && document.activeElement === uploading.el};
        },
        async finishUpload(args) {
          const el = uploading?.id === args.id ? uploading.el : null;
          if (!el || !el.isConnected || el.files?.length !== 1) return {ok:false};
          const file = el.files[0];
          if (file.size !== args.size || file.name !== args.name) return {ok:false};
          // Materialize an in-memory File before native deletes the temporary
          // picker file. Later form submission must not depend on a disk path.
          const bytes = await file.arrayBuffer();
          if (!el.isConnected || el.files[0] !== file || uploading?.el !== el) return {ok:false};
          const transfer = new DataTransfer();
          transfer.items.add(new File([bytes],file.name,{type:file.type,lastModified:file.lastModified}));
          el.files = transfer.files; uploading = null; revision++;
          return {ok:true};
        }
      };
    })();
    """#
}
