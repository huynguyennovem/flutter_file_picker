#if os(iOS)
import AVFoundation
import Flutter
import Foundation
import PhotosUI
import UniformTypeIdentifiers
import UIKit

final class IOSFilePickerHandler: NSObject,
    FlutterStreamHandler,
    PHPickerViewControllerDelegate,
    UIDocumentPickerDelegate,
    UIAdaptivePresentationControllerDelegate {

    private var result: FlutterResult?
    private var eventSink: FlutterEventSink?
    private var allowMultipleSelection = false
    private var loadDataToMemory = false
    private var isDirectoryPicker = false
    private var isSaveFile = false
    private var activePickerController: UIViewController?
    private var isCancellationRequested = false
    private var activeMediaPickerType: String?
    private weak var loadingOverlayView: UIView?

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "cancelCurrentRequest" {
            result(cancelCurrentRequest())
            return
        }

        if self.result != nil {
            result(
                FlutterError(
                    code: "multiple_request",
                    message: "Cancelled by a second request",
                    details: nil))
            return
        }

        self.result = result
        isCancellationRequested = false

        if call.method == "clear" {
            self.result?(clearTemporaryFiles())
            self.result = nil
            return
        }

        if call.method == "dir" {
            isDirectoryPicker = true
            allowMultipleSelection = false
            presentDocumentPicker(
                contentTypes: [.folder],
                allowsMultipleSelection: false,
                asDirectoryPicker: true)
            return
        }

        guard let arguments = call.arguments as? [String: Any] else {
            self.result?(
                FlutterError(
                    code: "invalid_arguments",
                    message: "Expected method arguments as a map.",
                    details: nil))
            self.result = nil
            return
        }

        allowMultipleSelection =
            (arguments["allowMultipleSelection"] as? Bool) ?? false
        loadDataToMemory = (arguments["withData"] as? Bool) ?? false

        switch call.method {
        case "any":
            activeMediaPickerType = nil
            presentDocumentPicker(
                contentTypes: [.item],
                allowsMultipleSelection: allowMultipleSelection,
                asDirectoryPicker: false)
        case "custom":
            activeMediaPickerType = nil
            let allowed = arguments["allowedExtensions"] as? [String] ?? []
            let contentTypes = resolveCustomContentTypes(allowed)
            if contentTypes.isEmpty {
                self.result?(
                    FlutterError(
                        code: "Unsupported file extension",
                        message:
                            "If you are providing extension filters make sure that you are only using FileType.custom and the extension are provided without the dot, (ie., jpg instead of .jpg).",
                        details: nil))
                self.result = nil
                return
            }
            presentDocumentPicker(
                contentTypes: contentTypes,
                allowsMultipleSelection: allowMultipleSelection,
                asDirectoryPicker: false)
        case "image", "video", "media":
            activeMediaPickerType = call.method
            presentMediaPicker(
                type: call.method,
                allowsMultipleSelection: allowMultipleSelection)
        case "audio":
            activeMediaPickerType = nil
            presentDocumentPicker(
                contentTypes: [.audio],
                allowsMultipleSelection: allowMultipleSelection,
                asDirectoryPicker: false)
        case "save":
            activeMediaPickerType = nil
            saveFile(arguments)
        default:
            result(FlutterMethodNotImplemented)
            self.result = nil
        }
    }

    func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink)
        -> FlutterError?
    {
        eventSink = events
        return nil
    }

    func onCancel(withArguments _: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    func picker(
        _ picker: PHPickerViewController,
        didFinishPicking results: [PHPickerResult]
    ) {
        picker.dismiss(animated: true)
        activePickerController = nil

        guard let currentResult = result else {
            return
        }

        if results.isEmpty {
            hideLoadingOverlay()
            currentResult(nil)
            result = nil
            eventSink?(false)
            isCancellationRequested = false
            activeMediaPickerType = nil
            return
        }

        eventSink?(true)
        showLoadingOverlay(for: activeMediaPickerType, selectionCount: results.count)
        let group = DispatchGroup()
        var resolved: [[String: Any]] = []
        let resolvedLock = NSLock()

        for item in results {
            group.enter()
            item.itemProvider.loadFileRepresentation(
                forTypeIdentifier: UTType.item.identifier
            ) { [weak self] url, _ in
                defer { group.leave() }
                guard let self, let sourceURL = url,
                      let copiedURL = self.copyToTemporaryDirectory(sourceURL)
                else {
                    return
                }
                if let fileInfo = self.makeFileInfo(from: copiedURL) {
                    resolvedLock.lock()
                    resolved.append(fileInfo)
                    resolvedLock.unlock()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else {
                return
            }
            eventSink?(false)
            self.hideLoadingOverlay()
            if self.isCancellationRequested {
                self.isCancellationRequested = false
                self.activeMediaPickerType = nil
                return
            }
            currentResult(resolved.isEmpty ? nil : resolved)
            self.result = nil
            self.activeMediaPickerType = nil
        }
    }

    func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
        hideLoadingOverlay()
        activePickerController = nil
        result?(nil)
        result = nil
        isCancellationRequested = false
        activeMediaPickerType = nil
    }

    func presentationControllerDidDismiss(
        _: UIPresentationController
    ) {
        hideLoadingOverlay()
        activePickerController = nil
        if result != nil {
            result?(nil)
            result = nil
        }
        isCancellationRequested = false
        activeMediaPickerType = nil
    }

    func documentPicker(
        _: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let currentResult = result else {
            return
        }

        if isSaveFile {
            hideLoadingOverlay()
            currentResult(urls.first?.path)
            result = nil
            isSaveFile = false
            activePickerController = nil
            isCancellationRequested = false
            activeMediaPickerType = nil
            return
        }

        if isDirectoryPicker {
            hideLoadingOverlay()
            currentResult(urls.first?.path)
            result = nil
            isDirectoryPicker = false
            activePickerController = nil
            isCancellationRequested = false
            activeMediaPickerType = nil
            return
        }

        var resolved: [[String: Any]] = []

        for sourceURL in urls {
            guard let copiedURL = copyToTemporaryDirectory(sourceURL),
                  let fileInfo = makeFileInfo(from: copiedURL)
            else {
                continue
            }
            resolved.append(fileInfo)
        }

        hideLoadingOverlay()
        currentResult(resolved.isEmpty ? nil : resolved)
        result = nil
        activePickerController = nil
        isCancellationRequested = false
        activeMediaPickerType = nil
    }

    private func presentMediaPicker(type: String, allowsMultipleSelection: Bool) {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = allowsMultipleSelection ? 0 : 1

        switch type {
        case "image":
            configuration.filter = .images
        case "video":
            configuration.filter = .videos
        default:
            configuration.filter = .any(of: [.images, .videos])
        }

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        picker.presentationController?.delegate = self
        activePickerController = picker
        topViewController()?.present(picker, animated: true)
    }

    private func presentDocumentPicker(
        contentTypes: [UTType],
        allowsMultipleSelection: Bool,
        asDirectoryPicker: Bool
    ) {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: !asDirectoryPicker)
        picker.delegate = self
        picker.presentationController?.delegate = self
        picker.allowsMultipleSelection = allowsMultipleSelection
        activePickerController = picker
        topViewController()?.present(picker, animated: true)
    }

    private func saveFile(_ arguments: [String: Any]) {
        isSaveFile = true
        let fileName = (arguments["fileName"] as? String) ?? ""
        let bytes = arguments["bytes"] as? FlutterStandardTypedData

        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(fileName)

        do {
            if FileManager.default.fileExists(atPath: tempFile.path) {
                try FileManager.default.removeItem(at: tempFile)
            }
            if let data = bytes?.data {
                try data.write(to: tempFile, options: .atomic)
            }
        } catch {
            result?(
                FlutterError(
                    code: "Failed to write file",
                    message: error.localizedDescription,
                    details: nil))
            result = nil
            isSaveFile = false
            return
        }

        let picker = UIDocumentPickerViewController(
            forExporting: [tempFile],
            asCopy: true)
        picker.delegate = self
        picker.presentationController?.delegate = self
        activePickerController = picker
        topViewController()?.present(picker, animated: true)
    }

    private func cancelCurrentRequest() -> Bool {
        let hadRequest = result != nil || activePickerController != nil

        guard hadRequest else {
            return false
        }

        isCancellationRequested = true
        eventSink?(false)
        result?(nil)
        result = nil
        isDirectoryPicker = false
        isSaveFile = false
        activeMediaPickerType = nil
        hideLoadingOverlay()

        if let activePickerController {
            activePickerController.dismiss(animated: true)
            self.activePickerController = nil
        }

        return true
    }

    private func showLoadingOverlay(for mediaType: String?, selectionCount: Int) {
        DispatchQueue.main.async {
            self.hideLoadingOverlay()

            guard let window = self.topViewController()?.view.window
                    ?? UIApplication.shared.windows.first(where: { $0.isKeyWindow })
            else {
                return
            }

            let overlay = UIView(frame: window.bounds)
            overlay.backgroundColor = UIColor.black.withAlphaComponent(0.32)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]

            let card = UIView()
            card.backgroundColor = .systemBackground
            card.layer.cornerRadius = 24
            card.layer.shadowColor = UIColor.black.withAlphaComponent(0.18).cgColor
            card.layer.shadowOpacity = 1
            card.layer.shadowRadius = 18
            card.layer.shadowOffset = CGSize(width: 0, height: 8)
            card.translatesAutoresizingMaskIntoConstraints = false

            let indicator = UIActivityIndicatorView(style: .large)
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.startAnimating()

            let titleLabel = UILabel()
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.font = .preferredFont(forTextStyle: .headline)
            titleLabel.textColor = .label
            titleLabel.numberOfLines = 0
            titleLabel.textAlignment = .center
            titleLabel.text = self.loadingOverlayTitle(
                for: mediaType,
                selectionCount: selectionCount)

            let messageLabel = UILabel()
            messageLabel.translatesAutoresizingMaskIntoConstraints = false
            messageLabel.font = .preferredFont(forTextStyle: .subheadline)
            messageLabel.textColor = .secondaryLabel
            messageLabel.numberOfLines = 0
            messageLabel.textAlignment = .center
            messageLabel.text = "Please wait while the selected files are prepared."

            card.addSubview(indicator)
            card.addSubview(titleLabel)
            card.addSubview(messageLabel)
            overlay.addSubview(card)
            window.addSubview(overlay)

            NSLayoutConstraint.activate([
                card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                card.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 24),
                card.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -24),
                card.widthAnchor.constraint(lessThanOrEqualToConstant: 360),

                indicator.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
                indicator.centerXAnchor.constraint(equalTo: card.centerXAnchor),

                titleLabel.topAnchor.constraint(equalTo: indicator.bottomAnchor, constant: 18),
                titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
                titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),

                messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
                messageLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
                messageLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
                messageLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
            ])

            self.loadingOverlayView = overlay
        }
    }

    private func hideLoadingOverlay() {
        DispatchQueue.main.async {
            self.loadingOverlayView?.removeFromSuperview()
            self.loadingOverlayView = nil
        }
    }

    private func loadingOverlayTitle(
        for mediaType: String?,
        selectionCount: Int
    ) -> String {
        switch mediaType {
        case "video":
            return selectionCount > 1
                ? "Loading selected videos"
                : "Loading selected video"
        case "image":
            return selectionCount > 1
                ? "Loading selected images"
                : "Loading selected image"
        default:
            return selectionCount > 1
                ? "Loading selected files"
                : "Loading selected file"
        }
    }

    private func resolveCustomContentTypes(_ allowedExtensions: [String]) -> [UTType] {
        allowedExtensions.compactMap { ext in
            let sanitized = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
            return UTType(filenameExtension: sanitized)
        }
    }

    private func clearTemporaryFiles() -> Bool {
        let tmpDirectory = NSTemporaryDirectory()

        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: tmpDirectory)
            for file in files {
                let filePath = (tmpDirectory as NSString).appendingPathComponent(file)
                try FileManager.default.removeItem(atPath: filePath)
            }
            return true
        } catch {
            return false
        }
    }

    private func topViewController() -> UIViewController? {
        let window = UIApplication.shared.windows.first { $0.isKeyWindow }
        var topController = window?.rootViewController

        while topController?.presentedViewController != nil {
            topController = topController?.presentedViewController
        }

        return topController
    }

    private func copyToTemporaryDirectory(_ sourceURL: URL) -> URL? {
        let destinationURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(sourceURL.lastPathComponent)

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            return nil
        }
    }

    private func makeFileInfo(from fileURL: URL) -> [String: Any]? {
        do {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            let size = values.fileSize ?? 0
            let data = loadDataToMemory ? try Data(contentsOf: fileURL) : nil

            var fileInfo: [String: Any] = [
                "path": fileURL.path,
                "identifier": fileURL.absoluteString,
                "name": fileURL.lastPathComponent,
                "size": size,
            ]

            if let data {
                fileInfo["bytes"] = FlutterStandardTypedData(bytes: data)
            }

            return fileInfo
        } catch {
            return nil
        }
    }
}
#endif
