import AppKit
import Foundation

@MainActor
internal final class SettingsController: NSObject {
  private let keyStore: any APIKeyStoring
  private let window: NSWindow
  private let apiKeyStatusLabel = NSTextField(wrappingLabelWithString: "")
  private let apiKeyField = NSSecureTextField()
  private lazy var apiKeySaveButton = NSButton(
    title: "Save", target: self, action: #selector(saveAPIKey))
  private lazy var apiKeyRemoveButton = NSButton(
    title: "Remove", target: self, action: #selector(removeAPIKey))
  private let captureGuideLabel = NSTextField(wrappingLabelWithString: "")

  init(keyStore: any APIKeyStoring) {
    self.keyStore = keyStore
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 1),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.title = "Galpi Settings"
    window.isReleasedWhenClosed = false
    super.init()
    configureWindow()
  }

  func show() {
    refreshAPIKeyStatus()
    NSApp.activate(ignoringOtherApps: true)
    window.center()
    window.makeKeyAndOrderFront(nil)
  }

  private func configureWindow() {
    let apiKeyHeading = NSTextField(labelWithString: "OpenAI API Key")
    apiKeyHeading.font = .boldSystemFont(ofSize: 13)

    apiKeyStatusLabel.setAccessibilityLabel("OpenAI API key status")
    apiKeyStatusLabel.preferredMaxLayoutWidth = 400

    apiKeyField.setAccessibilityHelp(
      "Stored only in Keychain. The existing key is never displayed or copied into SQLite.")

    let apiKeyButtons = NSStackView(views: [apiKeySaveButton, apiKeyRemoveButton])
    apiKeyButtons.orientation = .horizontal
    apiKeyButtons.spacing = 8

    let captureHeading = NSTextField(labelWithString: "Capture Privacy & Shortcut")
    captureHeading.font = .boldSystemFont(ofSize: 13)

    captureGuideLabel.stringValue = ReleaseGuidance.capturePrivacy
    captureGuideLabel.setAccessibilityLabel("Capture privacy and shortcut guidance")
    captureGuideLabel.preferredMaxLayoutWidth = 400

    let separator = NSBox()
    separator.boxType = .separator

    let stack = NSStackView(views: [
      apiKeyHeading, apiKeyStatusLabel, apiKeyField, apiKeyButtons,
      separator,
      captureHeading, captureGuideLabel,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    stack.setCustomSpacing(20, after: apiKeyButtons)
    stack.setCustomSpacing(20, after: separator)
    [apiKeyStatusLabel, apiKeyField, captureGuideLabel, separator].forEach {
      $0.widthAnchor.constraint(equalToConstant: 420).isActive = true
    }
    stack.translatesAutoresizingMaskIntoConstraints = false

    let contentView = NSView()
    contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor),
      stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
    window.contentView = contentView
    window.layoutIfNeeded()
  }

  private func refreshAPIKeyStatus() {
    let present: Bool
    do {
      present = try keyStore.contains()
    } catch {
      apiKeyStatusLabel.stringValue = "Keychain access failed."
      apiKeyRemoveButton.isHidden = true
      return
    }
    apiKeyStatusLabel.stringValue = present ? ReleaseGuidance.apiKeyStored : ReleaseGuidance.apiKeyMissing
    apiKeyField.placeholderString = present ? "Replacement API key" : "API key"
    apiKeyField.setAccessibilityLabel(present ? "Replacement OpenAI API key" : "OpenAI API key")
    apiKeyField.stringValue = ""
    apiKeySaveButton.title = present ? "Replace" : "Save"
    apiKeyRemoveButton.isHidden = !present
  }

  @objc private func saveAPIKey() {
    do {
      try keyStore.save(apiKeyField.stringValue)
      refreshAPIKeyStatus()
    } catch KeychainAPIKeyStoreError.emptyAPIKey {
      showSanitizedAlert(title: "Key Not Saved", message: "Enter a nonempty key and try again.")
    } catch {
      showSanitizedAlert(title: "Key Not Saved", message: "Keychain access failed.")
    }
  }

  @objc private func removeAPIKey() {
    do {
      try keyStore.delete()
      refreshAPIKeyStatus()
    } catch {
      showSanitizedAlert(title: "Key Not Removed", message: "Keychain access failed.")
    }
  }

  private func showSanitizedAlert(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}
