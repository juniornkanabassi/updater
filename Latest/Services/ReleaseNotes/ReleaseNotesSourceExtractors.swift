import Foundation

extension ReleaseNotesMarkup {
  static func usesSourceSpecificTextExtraction(for url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host.contains("chromereleases.googleblog.com") || host.contains("navicat.com")
      || host.contains("zed.dev") || host.contains("zoom.com")
  }

  static func relevantChangelogText(
    fromHTML html: String, version: String?, pageURL: URL, allowFirstSectionFallback: Bool
  ) -> String? {
    if let relevantText = NavicatReleaseNotesExtractor.navicatMacReleaseText(
      fromHTML: html, version: version, pageURL: pageURL)
    {
      return relevantText
    }

    if let relevantText = ZedReleaseNotesExtractor.zedReleaseText(
      fromHTML: html, version: version, pageURL: pageURL)
    {
      return relevantText
    }

    if let relevantText = ZoomReleaseNotesExtractor.zoomReleaseText(
      fromHTML: html, version: version, pageURL: pageURL)
    {
      return relevantText
    }

    if let relevantText = ChromeReleaseNotesExtractor.chromeDesktopReleaseText(
      fromHTML: html, version: version, pageURL: pageURL)
    {
      return relevantText
    }
    if pageURL.host?.localizedCaseInsensitiveContains("chromereleases.googleblog.com") == true {
      return nil
    }

    if ["md", "mdx"].contains(pageURL.pathExtension.lowercased()) {
      let markdown = Self.normalizedPlainText(html)
      return Self.relevantText(
        from: markdown, version: version, allowFirstSectionFallback: allowFirstSectionFallback)
        ?? (Self.isUsefulReleaseNotesText(markdown, relevantVersion: version)
          && pageURL.pathExtension == "mdx" ? markdown : nil)
    }
    let preferredSuffix =
      pageURL.host?.localizedCaseInsensitiveContains("obsidian.md") == true ? "Desktop" : nil
    guard let text = ReleaseNotesDocument.markdown(fromHTML: html, baseURL: pageURL),
      let relevantText = Self.relevantText(
        from: text, version: version, allowFirstSectionFallback: allowFirstSectionFallback,
        preferredSuffix: preferredSuffix),
      Self.isUsefulReleaseNotesText(relevantText, relevantVersion: version)
    else {
      return nil
    }

    return relevantText
  }
}
