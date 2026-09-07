import AppKit
import Foundation
import Network
import os.log

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let panelController = NonactivatingPanelController()
  private let performanceLog = OSLog(subsystem: "com.galpi.app", category: "CapturePerformance")
  private let keyStore = KeychainAPIKeyStore()
  private lazy var settingsController = SettingsController(keyStore: keyStore)
  private let networkMonitor = NWPathMonitor()
  private let networkQueue = DispatchQueue(label: "com.galpi.network-path")
  private var statusItem: NSStatusItem?
  private var database: AppDatabase?
  private var lookupExecutor: LookupExecutor?
  private var libraryController: LibraryController?
  private var notificationTokens: [NSObjectProtocol] = []
  private var workspaceNotificationTokens: [NSObjectProtocol] = []
  private var terminationState = TerminationLifecycleState()

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.servicesProvider = self
    configureStatusItem()
    configurePersistenceAndLookup()
    configurePanelActions()
    observeRecoveryTriggers()
  }

  func applicationWillTerminate(_ notification: Notification) {
    networkMonitor.cancel()
    for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    for token in workspaceNotificationTokens {
      NSWorkspace.shared.notificationCenter.removeObserver(token)
    }
    notificationTokens.removeAll()
    workspaceNotificationTokens.removeAll()
    panelController.shutdown()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let lookupExecutor else { return .terminateNow }
    guard terminationState.begin() else { return .terminateLater }
    Task {
      await lookupExecutor.shutdown()
      await MainActor.run {
        guard self.terminationState.complete() else { return }
        sender.reply(toApplicationShouldTerminate: true)
      }
    }
    return .terminateLater
  }

  @objc func collectWordContext(
    _ pasteboard: NSPasteboard,
    userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) {
    let selectedText = pasteboard.string(forType: .string) ?? ""
    os_signpost(.event, log: performanceLog, name: "Service Callback")
    do {
      let document = try CaptureDocument(rawText: selectedText)
      panelController.show(document: document)
    } catch {
      return
    }
  }

  private func configureStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.title = "Galpi"
    item.button?.setAccessibilityLabel("Galpi status menu")
    item.button?.setAccessibilityHelp("Open Galpi Library, Settings, or Quit.")
    let menu = NSMenu()
    menu.addItem(
      withTitle: "Library…", action: #selector(showLibrary), keyEquivalent: "l")
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Galpi", action: #selector(quit), keyEquivalent: "q")
    menu.items.forEach { $0.target = self }
    item.menu = menu
    statusItem = item
  }

  private func configurePersistenceAndLookup() {
    do {
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
        create: true)
      let directory = support.appendingPathComponent("Galpi", isDirectory: true)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let database = try AppDatabase(path: directory.appendingPathComponent("Galpi.sqlite"))
      self.database = database

      let executor = LookupExecutor(
        database: database,
        keyStore: keyStore,
        client: DefinitionClient(model: LookupExecutor.model),
        stateChanged: { [weak self] state in
          Task { @MainActor in self?.handleLookupState(state) }
        })
      lookupExecutor = executor

      let libraryController = LibraryController(database: database)
      libraryController.retryHandler = { [weak self] id in
        guard let executor = self?.lookupExecutor else { return }
        Task {
          let result = await executor.manualRetryFailed(encounterID: id)
          await MainActor.run {
            self?.panelController.updateLookup(
              encounterID: id, message: Self.retryMessage(for: result),
              presentation: Self.retryPresentation(for: result))
            self?.libraryController?.showOperationResult(
              Self.retryMessage(for: result), reloadAfterSuccess: result == .accepted)
          }
        }
      }
      libraryController.retryAllHandler = { [weak self] in
        guard let executor = self?.lookupExecutor else { return }
        Task {
          let results = await executor.manualRetryAllFailed()
          await MainActor.run {
            let summary = LibraryRetrySummary(results: results)
            self?.libraryController?.showOperationResult(
              summary.message, reloadAfterSuccess: summary.shouldReload)
          }
        }
      }
      libraryController.deleteUnresolvedHandler = { [weak self] id in
        guard let executor = self?.lookupExecutor else { return }
        Task {
          let result = await executor.deleteUnresolved(encounterID: id)
          await MainActor.run {
            self?.libraryController?.showOperationResult(
              Self.deleteMessage(for: result), reloadAfterSuccess: result == .accepted)
          }
        }
      }
      libraryController.settingsHandler = { [weak self] in self?.showSettings() }
      self.libraryController = libraryController

      networkMonitor.pathUpdateHandler = { [weak executor] path in
        guard let executor else { return }
        let state: LookupConnectivity = path.status == .satisfied ? .satisfied : .unsatisfied
        Task { await executor.setConnectivity(state) }
      }
      networkMonitor.start(queue: networkQueue)
      Task { await executor.startupRecovery() }
    } catch {
      showSanitizedAlert(
        title: "Local Storage Unavailable",
        message: "Galpi could not open its local database. Lookups and Library will be unavailable until this is resolved.")
      let unavailableLibrary = LibraryController(viewModel: UnavailableLibraryDataProvider())
      unavailableLibrary.settingsHandler = { [weak self] in self?.showSettings() }
      libraryController = unavailableLibrary
    }
  }

  private func configurePanelActions() {
    panelController.confirmationHandler = { [weak self] capture in
      self?.persistConfirmation(capture)
    }
    panelController.openSettingsHandler = { [weak self] in self?.showSettings() }
    panelController.retryHandler = { [weak self] id in
      guard let self, let executor = self.lookupExecutor else { return }
      Task {
        let result = await executor.manualRetry(encounterID: id)
        await MainActor.run {
          self.panelController.updateLookup(
            encounterID: id, message: Self.retryMessage(for: result),
            presentation: Self.retryPresentation(for: result))
        }
      }
    }
  }

  private func persistConfirmation(_ capture: ConfirmedCapture) -> String? {
    guard let database, let lookupExecutor else { return nil }
    let id = UUID().uuidString
    let input = PendingEncounterInput(id: id, confirmedCapture: capture)
    do {
      _ = try database.createPending(input, nowMilliseconds: capture.capturedAtMilliseconds)
      libraryController?.notifyDatabaseChanged()
      Task { await lookupExecutor.offer(encounterID: id) }
      return id
    } catch {
      return nil
    }
  }

  private func handleLookupState(_ state: LookupExecutorState) {
    switch state {
    case .waitingForConnectivity:
      panelController.updateCurrentLookup(
        message: "Saved locally — waiting for connection", presentation: .waitingForConnectivity)
    case .running(let id):
      panelController.updateLookup(
        encounterID: id, message: "Looking up…", presentation: .running)
    case .retryScheduled(let id, let kind, let attempt, _):
      panelController.updateLookup(
        encounterID: id,
        message: "\(kind.sanitizedMessage) Automatic retry \(attempt)/5 scheduled",
        presentation: .retryScheduled,
        showRetry: true)
    case .succeeded(let id, let entry):
      panelController.updateLookup(
        encounterID: id,
        message: "Saved contextual definition",
        presentation: .succeeded,
        koreanGloss: entry.koreanGloss,
        englishDefinition: entry.englishDefinition)
    case .failed(let id, let kind):
      panelController.updateLookup(
        encounterID: id,
        message: kind.sanitizedMessage,
        presentation: .failed(
          settingsAvailable: kind == .missingKey || kind == .authentication || kind == .permission,
          retryAvailable: kind != .missingKey),
        showSettings: kind == .missingKey || kind == .authentication || kind == .permission,
        showRetry: kind != .missingKey)
    case .storageUnavailable(let id):
      if let id {
        panelController.updateLookup(
          encounterID: id,
          message:
            "Local storage is unavailable. Galpi retries transient failures; use Library Retry after storage is restored.",
          presentation: .storageUnavailable
        )
      } else {
        panelController.updateCurrentLookup(
          message:
            "Local storage is unavailable. Galpi retries transient failures; manual recovery may be required.",
          presentation: .storageUnavailable
        )
      }
    }
    if state.changesLibrary { libraryController?.notifyDatabaseChanged() }
  }

  private func observeRecoveryTriggers() {
    let wake = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let executor = self?.lookupExecutor else { return }
        await executor.startupRecovery()
      }
    }
    workspaceNotificationTokens.append(wake)

    let clockChange = NotificationCenter.default.addObserver(
      forName: .NSSystemClockDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let executor = self?.lookupExecutor else { return }
        await executor.startupRecovery()
      }
    }
    notificationTokens.append(clockChange)
  }

  @objc private func showSettings() {
    settingsController.show()
  }

  @objc private func showLibrary() {
    libraryController?.show()
  }

  @objc private func quit() { NSApp.terminate(nil) }

  private func showSanitizedAlert(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  private static func retryMessage(for result: LookupActionResult) -> String {
    switch result {
    case .accepted: "Manual retry queued"
    case .busy: "Lookup is already running"
    case .notFound: "Lookup is no longer retryable"
    case .storageUnavailable: "Local storage is unavailable"
    }
  }

  private static func retryPresentation(for result: LookupActionResult) -> CapturePresentationState {
    switch result {
    case .accepted, .busy:
      return .queued
    case .notFound:
      return .failed(settingsAvailable: false, retryAvailable: false)
    case .storageUnavailable:
      return .storageUnavailable
    }
  }

  private static func deleteMessage(for result: LookupActionResult) -> String {
    switch result {
    case .accepted: "Lookup deleted"
    case .busy: "Lookup is already running"
    case .notFound: "Lookup was already removed"
    case .storageUnavailable: "Local storage is unavailable"
    }
  }
}

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
