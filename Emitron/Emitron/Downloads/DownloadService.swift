/// Copyright (c) 2019 Razeware LLC
/// 
/// Permission is hereby granted, free of charge, to any person obtaining a copy
/// of this software and associated documentation files (the "Software"), to deal
/// in the Software without restriction, including without limitation the rights
/// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
/// copies of the Software, and to permit persons to whom the Software is
/// furnished to do so, subject to the following conditions:
/// 
/// The above copyright notice and this permission notice shall be included in
/// all copies or substantial portions of the Software.
/// 
/// Notwithstanding the foregoing, you may not use, copy, modify, merge, publish,
/// distribute, sublicense, create a derivative work, and/or sell copies of the
/// Software in any work that is designed, intended, or marketed for pedagogical or
/// instructional purposes related to programming, coding, application development,
/// or information technology.  Permission for such use, copying, modification,
/// merger, publication, distribution, sublicensing, creation of derivative works,
/// or sale is expressly withheld.
/// 
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
/// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
/// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
/// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
/// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
/// THE SOFTWARE.

import Foundation
import Combine
import Network

enum DownloadServiceError: Error {
  case unableToCancelDownload
  case unableToDeleteDownload
}

final class DownloadService {
  enum Status {
    case active
    case inactive
    
    static func status(expensive: Bool, expensiveAllowed: Bool) -> Status {
      if expensive && !expensiveAllowed {
        return .inactive
      }
      return .active
    }
  }
  
  // MARK: Properties
  private let persistenceStore: PersistenceStore
  private let userModelController: UserModelController
  private var userModelControllerSubscription: AnyCancellable?
  private let videosServiceProvider: VideosService.Provider
  private var videosService: VideosService?
  private let queueManager: DownloadQueueManager
  private let downloadProcessor = DownloadProcessor()
  private var processingSubscriptions = Set<AnyCancellable>()
  
  private let networkMonitor = NWPathMonitor()
  private var status: Status = .inactive
  private var settingsSubscription: AnyCancellable?
  private var downloadQueueSubscription: AnyCancellable?
  
  private var downloadQuality: Attachment.Kind {
    SettingsManager.current.downloadQuality
  }
  private lazy var downloadsDirectory: URL = {
    let fileManager = FileManager.default
    let documentsDirectories = fileManager.urls(for: .documentDirectory, in: .userDomainMask)
    guard let documentsDirectory = documentsDirectories.first else {
      preconditionFailure("Unable to locate the documents directory")
    }
    
    return documentsDirectory.appendingPathComponent("downloads", isDirectory: true)
  }()
  
  var backgroundSessionCompletionHandler: (() -> Void)? {
    get {
      downloadProcessor.backgroundSessionCompletionHandler
    }
    set {
      downloadProcessor.backgroundSessionCompletionHandler = newValue
    }
  }
  
  // MARK: Initialisers
  init(persistenceStore: PersistenceStore, userModelController: UserModelController, videosServiceProvider: VideosService.Provider? = .none) {
    self.persistenceStore = persistenceStore
    self.userModelController = userModelController
    self.queueManager = DownloadQueueManager(persistenceStore: persistenceStore, maxSimultaneousDownloads: 3)
    self.videosServiceProvider = videosServiceProvider ?? { VideosService(client: $0) }
    self.userModelControllerSubscription = userModelController.objectDidChange.sink { [weak self] in
      self?.stopProcessing()
      self?.checkPermissions()
      self?.startProcessing()
    }
    self.downloadProcessor.delegate = self
    checkPermissions()
  }
  
  
  // MARK: Queue Management
  func startProcessing() {
    queueManager.pendingStream
      .sink(receiveCompletion: { completion in
        Failure
          .repositoryLoad(from: String(describing: type(of: self)), reason: "Error: \(completion)")
          .log()
      }, receiveValue: { [weak self] downloadQueueItem in
        guard let self = self, let downloadQueueItem = downloadQueueItem else { return }
        self.requestDownloadUrl(downloadQueueItem)
      })
      .store(in: &processingSubscriptions)
    
    queueManager.readyForDownloadStream
      .sink(receiveCompletion: { completion in
        Failure
          .repositoryLoad(from: String(describing: type(of: self)), reason: "Error: \(completion)")
          .log()
      }, receiveValue: { [weak self] downloadQueueItem in
        guard let self = self, let downloadQueueItem = downloadQueueItem else { return }
        self.enqueue(downloadQueueItem: downloadQueueItem)
      })
      .store(in: &processingSubscriptions)
    
    // The download queue subscription is part of the
    // network monitoring process.
    checkQueueStatus()
  }
  
  func stopProcessing() {
    processingSubscriptions.forEach { $0.cancel() }
    processingSubscriptions = []
    
    downloadQueueSubscription?.cancel()
  }
}

// MARK: - DownloadAction Methods
extension DownloadService: DownloadAction {  
  func requestDownload(contentId: Int, contentLookup: @escaping ContentLookup) -> RequestDownloadResult {
    guard videosService != nil else {
      Failure
        .fetch(from: String(describing: type(of: self)), reason: "User not allowed to request downloads")
        .log()
      return .problemRequestingDownload(Constants.downloadNotPermitted)
    }
    
    guard let contentPersistableState = contentLookup(contentId) else {
      Failure
        .loadFromPersistentStore(from: String(describing: type(of: self)), reason: "Unable to locate content to persist")
        .log()
      return .problemRequestingDownload(Constants.downloadContentNotFound)
    }
    
    do {
      // Let's ensure that all the relevant content is stored locally
      try persistenceStore.persistContentGraph(for: contentPersistableState, contentLookup: contentLookup)
      // Now create the appropriate download objects.
      try persistenceStore.createDownloads(for: contentPersistableState.content)
      // Send status message
      switch status {
      case .active:
        return .downloadRequestedSuccessfully
      case .inactive:
        return .downloadRequestedButQueueInactive
      }
    } catch {
      Failure
        .saveToPersistentStore(from: String(describing: type(of: self)), reason: "There was a problem requesting the download: \(error)")
        .log()
      return .problemRequestingDownload(Constants.downloadRequestProblem, error)
    }
  }
  
  func cancelDownload(contentId: Int) throws {
    do {
      // 1. Find the download.
      guard let download = try persistenceStore.download(forContentId: contentId) else { return }
      // 2. Cancel it. The delegate callback will handle deleting the value in the persistence store.
      try downloadProcessor.cancelDownload(download)
    } catch {
      Failure
        .deleteFromPersistentStore(from: String(describing: type(of: self)), reason: "There was a problem cancelling the download (contentId: \(contentId)): \(error)")
        .log()
      throw DownloadServiceError.unableToCancelDownload
    }
  }
  
  func deleteDownload(contentId: Int) throws {
    do {
      // 1. Find the download
      guard let download = try persistenceStore.download(forContentId: contentId) else { return }
      // 2. Delete the file from disk
      try deleteFile(for: download)
      // 3. Delete the persisted record
      if try !persistenceStore.deleteDownload(withId: download.id) {
        Failure
        .deleteFromPersistentStore(from: String(describing: type(of: self)), reason: "There was a problem deleting the Download record from the DB (contentId: \(contentId))")
        .log()
      }
    } catch {
      Failure
        .deleteFromPersistentStore(from: String(describing: type(of: self)), reason: "There was a problem deleting the download (contentId: \(contentId)): \(error)")
        .log()
      throw DownloadServiceError.unableToDeleteDownload
    }
  }
}

// MARK: - Internal methods
extension DownloadService {
  func requestDownloadUrl(_ downloadQueueItem: PersistenceStore.DownloadQueueItem) {
    guard let videosService = videosService else {
      Failure
        .downloadService(
          from: "requestDownloadUrl",
          reason: "User not allowed to request downloads."
      ).log()
      return
    }
    guard downloadQueueItem.download.remoteUrl == nil,
      downloadQueueItem.download.state == .pending,
      downloadQueueItem.content.contentType != .collection else {
        Failure
          .downloadService(from: "requestDownloadUrl",
                           reason: "Cannot request download URL for: \(downloadQueueItem.download)")
          .log()
      return
    }
    // Find the video ID
    guard let videoId = downloadQueueItem.content.videoIdentifier,
      videoId != 0 else {
        Failure
          .downloadService(
            from: "requestDownloadUrl",
            reason: "Unable to locate videoId for download: \(downloadQueueItem.download)"
        ).log()
      return
    }
    
    // Use the video service to request the URLs
    videosService.getVideoDownload(for: videoId) { [weak self] result in
      // Ensure we're still around
      guard let self = self else { return }
      var download = downloadQueueItem.download
      
      switch result {
      case .failure(let error):
        Failure
          .downloadService(from: "requestDownloadUrl",
                           reason: "Unable to obtain download URLs: \(error)")
          .log()
      case .success(let attachments):
        download.remoteUrl = attachments.first { $0.kind == self.downloadQuality }?.url
        download.lastValidatedAt = Date()
        download.state = .readyForDownload
      }
      
      // Update the state if required
      if download.remoteUrl == nil {
        download.state = .error
      }
      
      // Commit the changes
      do {
        try self.persistenceStore.update(download: download)
      } catch {
        Failure
          .downloadService(from: "requestDownloadUrl",
                           reason: "Unable to save download URL: \(error)")
          .log()
        self.transitionDownload(withID: download.id, to: .failed)
      }
    }
    
    // Move it on through the state machine
    self.transitionDownload(withID: downloadQueueItem.download.id, to: .urlRequested)
  }
  
  func enqueue(downloadQueueItem: PersistenceStore.DownloadQueueItem) {
    guard downloadQueueItem.download.remoteUrl != nil,
      downloadQueueItem.download.state == .readyForDownload else {
        Failure
          .downloadService(from: "enqueue",
                           reason: "Cannot enqueue download: \(downloadQueueItem.download)")
          .log()
      return
    }
    // Find the video ID
    guard let videoId = downloadQueueItem.content.videoIdentifier else {
      Failure
        .downloadService(from: "enqueue",
                         reason: "Unable to locate videoId for download: \(downloadQueueItem.download)")
        .log()
      return
    }
    
    // Generate filename
    let filename = "\(videoId).mp4"
    
    // Save local URL and filename
    var download = downloadQueueItem.download
    download.fileName = filename
    
    // Transition download to correct status
    // If file exists, update the download
    let fileManager = FileManager.default
    if let localUrl = download.localUrl, fileManager.fileExists(atPath: localUrl.path) {
      download.state = .complete
    } else {
      download.state = .enqueued
    }
    
    // Save
    do {
      try persistenceStore.update(download: download)
    } catch {
      Failure
        .saveToPersistentStore(from: String(describing: type(of: self)), reason: "Unable to enqueue donwload: \(error)")
        .log()
    }
  }
  
  private func prepareDownloadDirectory() {
    let fileManager = FileManager.default
    do {
      if !fileManager.fileExists(atPath: downloadsDirectory.path) {
        try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: false)
      }
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try downloadsDirectory.setResourceValues(values)
      #if DEBUG
      print("Download directory located at: \(downloadsDirectory.path)")
      #endif
    } catch {
      preconditionFailure("Unable to prepare downloads directory: \(error)")
    }
  }
  
  private func deleteExistingDownloads() {
    let fileManager = FileManager.default
    do {
      if fileManager.fileExists(atPath: downloadsDirectory.path) {
        try fileManager.removeItem(at: downloadsDirectory)
      }
      prepareDownloadDirectory()
    } catch {
      preconditionFailure("Unable to delete the contents of the downloads directory: \(error)")
    }
  }
  
  private func deleteFile(for download: Download) throws {
    guard let localUrl = download.localUrl else { return }
    let filemanager = FileManager.default
    if filemanager.fileExists(atPath: localUrl.path) {
      try filemanager.removeItem(at: localUrl)
    }
  }
  
  private func checkPermissions() {
    guard let user = userModelController.user else {
      // There's no user—delete everything
      destroyDownloads()
      videosService = .none
      return
    }
    if user.canDownload {
      // Allowed to download. Let's make a video service and the d/l dir
      prepareDownloadDirectory()
      if videosService == nil {
        videosService = videosServiceProvider(userModelController.client)
      }
    } else {
      // User doesn't have download permission. Delete everything and reset.
      destroyDownloads()
      videosService = .none
    }
  }
  
  private func destroyDownloads() {
    // This will delete the Download model records, via the delegate callback
    downloadProcessor.cancelAllDownloads()
    deleteExistingDownloads()
  }
}

// MARK: - DownloadProcesserDelegate Methods
extension DownloadService: DownloadProcessorDelegate {
  func downloadProcessor(_ processor: DownloadProcessor, downloadModelForDownloadWithId downloadId: UUID) -> DownloadProcessorModel? {
    do {
      return try persistenceStore.download(withId: downloadId)
    } catch {
      Failure
        .loadFromPersistentStore(from: String(describing: type(of: self)), reason: "Error finding download: \(error)")
        .log()
      return .none
    }
  }
  
  func downloadProcessor(_ processor: DownloadProcessor, didStartDownloadWithId downloadId: UUID) {
    transitionDownload(withID: downloadId, to: .inProgress)
  }
  
  func downloadProcessor(_ processor: DownloadProcessor, downloadWithId downloadId: UUID, didUpdateProgress progress: Double) {
    do {
      try persistenceStore.updateDownload(withId: downloadId, withProgress: progress)
    } catch {
      Failure
        .saveToPersistentStore(from: String(describing: type(of: self)), reason: "Unable to update progress on download: \(error)")
        .log()
    }
  }
  
  func downloadProcessor(_ processor: DownloadProcessor, didFinishDownloadWithId downloadId: UUID) {
    transitionDownload(withID: downloadId, to: .complete)
  }
  
  func downloadProcessor(_ processor: DownloadProcessor, didCancelDownloadWithId downloadId: UUID) {
    do {
      if try !persistenceStore.deleteDownload(withId: downloadId) {
        Failure
          .deleteFromPersistentStore(from: String(describing: type(of: self)), reason: "Unable to delete download: \(downloadId)")
          .log()
      }
    } catch {
      Failure
        .deleteFromPersistentStore(from: String(describing: type(of: self)), reason: "Unable to delete download: \(error)")
        .log()
    }
  }
  
  func downloadProcessor(_ processor: DownloadProcessor, didPauseDownloadWithId downloadId: UUID) {
    transitionDownload(withID: downloadId, to: .paused)
  }
  
  func downloadProcessor(_ processor: DownloadProcessor, didResumeDownloadWithId downloadId: UUID) {
    transitionDownload(withID: downloadId, to: .inProgress)
  }
  
  func downloadProcessor(_ processor: DownloadProcessor, downloadWithId downloadId: UUID, didFailWithError error: Error) {
    transitionDownload(withID: downloadId, to: .error)
    Failure
      .saveToPersistentStore(from: String(describing: type(of: self)), reason: "DownloadDidFailWithError: \(error)")
      .log()
  }
  
  private func transitionDownload(withID id: UUID, to state: Download.State) {
    do {
      try persistenceStore.transitionDownload(withId: id, to: state)
    } catch {
      Failure
        .saveToPersistentStore(from: String(describing: type(of: self)), reason: "Unable to transition download: \(error)")
        .log()
    }
  }
}


// MARK:- Functionality for the UI
extension DownloadService {
  func downloadList() -> AnyPublisher<[ContentSummaryState], Error> {
    persistenceStore
      .downloadList()
      .eraseToAnyPublisher()
  }
  
  func downloadedContentSummary(for contentId: Int) -> AnyPublisher<ContentSummaryState?, Error> {
    persistenceStore
      .downloadContentSummary(for: contentId)
      .eraseToAnyPublisher()
  }
  
  func contentSummaries(for contentIds: [Int]) -> AnyPublisher<[ContentSummaryState], Error> {
    persistenceStore
      .downloadContentSummary(for: contentIds)
      .eraseToAnyPublisher()
  }
}

// MARK:- Wifi Status Handling
extension DownloadService {
  private func configureWifiObservation() {
    // Track the network status
    networkMonitor.pathUpdateHandler = { [weak self] path in
      self?.checkQueueStatus()
    }
    networkMonitor.start(queue: DispatchQueue.global(qos: .utility))
    
    // Track the status of the wifi downloads setting
    settingsSubscription = SettingsManager.current
      .wifiOnlyDownloadsPublisher
      .removeDuplicates()
      .sink(receiveValue: { [weak self] (_) in
        self?.checkQueueStatus()
      })
  }
  
  private func checkQueueStatus() {
    let expensive = networkMonitor.currentPath.isExpensive
    let allowedExpensive = !SettingsManager.current.wifiOnlyDownloads
    let newStatus = Status.status(expensive: expensive, expensiveAllowed: allowedExpensive)
    
    if status == newStatus { return }
    
    status = newStatus
    switch status {
    case .active:
      resumeQueue()
    case .inactive:
      pauseQueue()
    }
  }
  
  private func pauseQueue() {
    // Cancel download queue processing
    downloadQueueSubscription?.cancel()
    
    // Pause all downloads already in the processor
    downloadProcessor.pauseAllDownloads()
  }
  
  private func resumeQueue() {
    // Start download queue processing
    downloadQueueSubscription = queueManager.downloadQueue
      .sink(receiveCompletion: { completion in
        switch completion {
        case .finished:
          print("Should never get here.... \(completion)")
        case .failure(let error):
          Failure
            .downloadService(from: String(describing: type(of: self)), reason: "DownloadQueue: \(error)")
            .log()
        }
      }, receiveValue: { [weak self] downloadQueueItems in
        guard let self = self else { return }
        downloadQueueItems.filter { $0.download.state == .enqueued }
          .forEach { (downloadQueueItem) in
            do {
              try self.downloadProcessor.add(download: downloadQueueItem.download)
            } catch {
              Failure
              .downloadService(from: String(describing: type(of: self)), reason: "Problem adding download: \(error)")
              .log()
              self.transitionDownload(withID: downloadQueueItem.download.id, to: .failed)
            }
        }
      })
    
    // Resume all downloads that the processor is already working on
    downloadProcessor.resumeAllDownloads()
  }
}
