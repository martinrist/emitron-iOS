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

import SwiftUI

struct ContentListView: View {
  @ObservedObject var contentRepository: ContentRepository
  var downloadAction: DownloadAction
  var contentScreen: ContentScreen
  var headerView: AnyView?

  var body: some View {
    contentView
  }

  private var contentView: AnyView {
    switch contentRepository.state {
    case .initial:
      contentRepository.reload()
      return AnyView(loadingView)
    case .loading:
      return AnyView(loadingView)
    case .loadingAdditional:
      return AnyView(listView)
    case .hasData where contentRepository.isEmpty:
      return AnyView(noResultsView)
    case .hasData:
      return AnyView(listView)
    case .failed:
      return AnyView(reloadView)
    }
  }

  private func cardTableNavView(withDelete: Bool = false) -> some View {
    ForEach(contentRepository.contents, id: \.id) { partialContent in
      ZStack {
        CardContainerView(
          model: partialContent,
          dynamicContentViewModel: self.contentRepository.dynamicContentViewModel(for: partialContent.id)
        )
          .padding(10)
        NavigationLink(
          destination: ContentDetailView(
            content: partialContent,
            childContentsViewModel: self.contentRepository.childContentsViewModel(for: partialContent.id),
            dynamicContentViewModel: self.contentRepository.dynamicContentViewModel(for: partialContent.id)
          )
        ) {
          EmptyView()
        }
          .buttonStyle(PlainButtonStyle())
          //HACK: to remove navigation chevrons
          .padding(.trailing, -10.0)
      }
    }
      .if(withDelete) { $0.onDelete(perform: self.delete) }
      .listRowInsets(EdgeInsets())
      .background(Color.backgroundColor)
  }
  
  private var appropriateCardsView: some View {
    if case .downloads = contentScreen {
      return cardTableNavView(withDelete: true)
    } else {
      return cardTableNavView(withDelete: false)
    }
  }
  
  private var listView: some View {
    List {
      if self.headerView != nil {
        Section(header: self.headerView) {
          self.appropriateCardsView
          self.loadMoreView
        }.listRowInsets(EdgeInsets())
      } else {
        self.appropriateCardsView
        self.loadMoreView
      }
    }
  }
  
  private var loadingView: some View {
    List {
      VStack {
        headerView
        Spacer(minLength: 50)
        LoadingView()
      }
        .listRowInsets(EdgeInsets())
    }
  }
  
  private var noResultsView: some View {
    List {
      NoResultsView(
        contentScreen: contentScreen,
        headerView: headerView
      )
        .listRowInsets(EdgeInsets())
    }
  }
  
  private var reloadView: some View {
    List {
      ReloadView(headerView: headerView) {
        self.contentRepository.reload()
      }
        .listRowInsets(EdgeInsets())
    }
  }
  
  private var loadMoreView: AnyView? {
    if contentRepository.totalContentNum > contentRepository.contents.count {
      return AnyView(
        // HACK: To put it in the middle we have to wrap it in Geometry Reader
        GeometryReader { _ in
          ActivityIndicator()
            .onAppear {
              self.contentRepository.loadMore()
            }
        }
      )
    } else {
      return nil
    }
  }

  private func delete(at offsets: IndexSet) {
    guard let index = offsets.first else {
      return
    }
    DispatchQueue.main.async {
      let content = self.contentRepository.contents[index]
      
      do {
        try self.downloadAction.deleteDownload(contentId: content.id)
      } catch {
        Failure
          .downloadAction(from: String(describing: type(of: self)), reason: "Unable to perform download action: \(error)")
        .log()
      }
    }
  }
}
