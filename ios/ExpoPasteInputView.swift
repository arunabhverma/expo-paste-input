import ExpoModulesCore
import UIKit
import ObjectiveC
import ImageIO

// Association key for storing the wrapper view reference on text input views
private var textInputWrapperKey: UInt8 = 0

// Weak wrapper to avoid retain cycles
private class WeakWrapper {
  weak var value: ExpoPasteInputView?
  init(_ value: ExpoPasteInputView) {
    self.value = value
  }
}

// Protocol to identify text input views that can be enhanced
private protocol TextInputEnhanceable: UIView {
  func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool
  func paste(_ sender: Any?)
}

extension UITextField: TextInputEnhanceable {}
extension UITextView: TextInputEnhanceable {}

private enum MediaPayload {
  case gif(Data)
  case imageData(Data)
  case image(UIImage)
}

class ExpoPasteInputView: ExpoView {
  private let onPaste = EventDispatcher()
  private let mediaProcessingQueue = DispatchQueue(label: "expo.modules.pasteinput.media-processing", qos: .userInitiated)
  private var textInputView: UIView?
  private var isMonitoring: Bool = false
  private var textDidChangeObserver: NSObjectProtocol?
  private weak var observedTextView: UITextView?
  private var isSanitizingAttachments: Bool = false
  private var originalAdaptiveImageGlyphSupport: Bool?
  private let gifTypes: Set<String> = ["com.compuserve.gif", "public.gif", "image/gif"]
  private let webpTypes: Set<String> = ["org.webmproject.webp", "public.webp", "image/webp"]
  // Track which classes have been swizzled (once per class, never unswizzle)
  private static var swizzledClasses: Set<String> = []
  
  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = false
    backgroundColor = .clear
    // Keep user interaction enabled so we can monitor, but pass through touches
    isUserInteractionEnabled = true
  }
  
  // Pass through all touch events to children - never intercept
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    // Always delegate to super first to check children
    let hitView = super.hitTest(point, with: event)
    
    // If we hit ourselves or nothing, return nil to pass through
    if hitView == self || hitView == nil {
      return nil
    }
    
    // Return the child view that was hit
    return hitView
  }
  
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    // Only return true if a child contains the point
    for subview in subviews.reversed() {
      let convertedPoint = subview.convert(point, from: self)
      if subview.point(inside: convertedPoint, with: event) {
        return true
      }
    }
    // Never claim the point for ourselves
    return false
  }
  
  override func didMoveToSuperview() {
    super.didMoveToSuperview()
    if superview != nil {
      startMonitoring()
    } else {
      stopMonitoring()
    }
  }
  
  override func didAddSubview(_ subview: UIView) {
    super.didAddSubview(subview)
    startMonitoring()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if !isMonitoring {
      startMonitoring()
    }
  }
  
  private func startMonitoring() {
    // Find TextInput in view hierarchy
    guard let textInput = findTextInputInView(self) else {
      return
    }

    if let currentTextInput = textInputView,
       isMonitoring,
       currentTextInput === textInput {
      if let textView = textInput as? UITextView {
        observeTextViewChanges(for: textView)
      }
      return
    }

    if let currentTextInput = textInputView,
       currentTextInput !== textInput {
      restoreTextInput(currentTextInput)
    }

    textInputView = textInput
    isMonitoring = true
    enhanceTextInput(textInput)
  }
  
  private func stopMonitoring() {
    guard isMonitoring else { return }
    isMonitoring = false
    
    // Only clear the association; swizzling stays global and is guarded
    if let textInput = textInputView {
      restoreTextInput(textInput)
    }
    textInputView = nil
  }
  
  private func enhanceTextInput(_ view: UIView) {
    // Store weak reference to this wrapper on the text input view to avoid retain cycles
    objc_setAssociatedObject(view, &textInputWrapperKey, WeakWrapper(self), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

    if #available(iOS 18.0, *) {
      originalAdaptiveImageGlyphSupport = currentAdaptiveImageGlyphSupport(for: view)
      setAdaptiveImageGlyphSupport(true, for: view)
    } else {
      originalAdaptiveImageGlyphSupport = nil
    }

    if let textView = view as? UITextView {
      observeTextViewChanges(for: textView)
    } else {
      stopObservingTextView()
    }
    
    // Swizzle canPerformAction and paste methods (once per class, never unswizzle)
    swizzleTextInputMethods(view)
  }
  
  private func restoreTextInput(_ view: UIView) {
    if #available(iOS 18.0, *),
       let originalAdaptiveImageGlyphSupport {
      setAdaptiveImageGlyphSupport(originalAdaptiveImageGlyphSupport, for: view)
    }
    originalAdaptiveImageGlyphSupport = nil

    if let textView = view as? UITextView,
       observedTextView === textView {
      stopObservingTextView()
    }

    // Only clear the association; swizzling stays global and is guarded
    objc_setAssociatedObject(view, &textInputWrapperKey, nil, .OBJC_ASSOCIATION_ASSIGN)
  }
  
  private func swizzleTextInputMethods(_ view: UIView) {
    let viewClass: AnyClass = type(of: view)
    let className = String(describing: viewClass)
    
    // Swizzle once per class, never unswizzle
    guard !ExpoPasteInputView.swizzledClasses.contains(className) else {
      return
    }
    
    var originalCanPerformIMP: IMP? = nil
    var originalPasteIMP: IMP? = nil
    var didSwizzle = false
    
    // Swizzle canPerformAction (once per class)
    let canPerformSelector = #selector(UIResponder.canPerformAction(_:withSender:))
    let swizzledCanPerformSelector = NSSelectorFromString("_expoPasteInput_canPerformAction:withSender:")
    
    if let originalMethod = class_getInstanceMethod(viewClass, canPerformSelector) {
      originalCanPerformIMP = method_getImplementation(originalMethod)
      
      // Only add swizzled method if it doesn't exist
      if class_getInstanceMethod(viewClass, swizzledCanPerformSelector) == nil {
        let swizzledImplementation: @convention(block) (AnyObject, Selector, Any?) -> Bool = { object, action, sender in
          // Check if this text input is associated with a wrapper
          if let weakWrapper = objc_getAssociatedObject(object, &textInputWrapperKey) as? WeakWrapper,
             let wrapper = weakWrapper.value {
            // Only process if this is our wrapped text input
            if action == #selector(UIResponderStandardEditActions.paste(_:)) {
              // IMPORTANT:
              // Do not read UIPasteboard content here. iOS may show the
              // "App would like to paste" privacy prompt on menu-open checks.
              // We allow paste action visibility and read the pasteboard only
              // when the user explicitly taps Paste in `paste(_:)`.
              return wrapper.shouldExposePasteAction(for: object)
            }
          }
          
          // Call original implementation
          if let originalIMP = originalCanPerformIMP {
            typealias OriginalIMP = @convention(c) (AnyObject, Selector, Selector, Any?) -> Bool
            let originalFunction = unsafeBitCast(originalIMP, to: OriginalIMP.self)
            return originalFunction(object, canPerformSelector, action, sender)
          }
          return false
        }
        
        let blockIMP = imp_implementationWithBlock(unsafeBitCast(swizzledImplementation, to: AnyObject.self))
        let types = method_getTypeEncoding(originalMethod)
        
        if class_addMethod(viewClass, swizzledCanPerformSelector, blockIMP, types) {
          if let swizzledMethod = class_getInstanceMethod(viewClass, swizzledCanPerformSelector) {
            method_exchangeImplementations(originalMethod, swizzledMethod)
            didSwizzle = true
          }
        }
      }
    }
    
    // Swizzle paste method (once per class)
    let pasteSelector = #selector(UIResponderStandardEditActions.paste(_:))
    let swizzledPasteSelector = NSSelectorFromString("_expoPasteInput_paste:")
    
    if let originalMethod = class_getInstanceMethod(viewClass, pasteSelector) {
      originalPasteIMP = method_getImplementation(originalMethod)
      
      // Only add swizzled method if it doesn't exist
      if class_getInstanceMethod(viewClass, swizzledPasteSelector) == nil {
        let swizzledImplementation: @convention(block) (AnyObject, Any?) -> Void = { object, sender in
          // Check if this text input is associated with a wrapper
          guard let weakWrapper = objc_getAssociatedObject(object, &textInputWrapperKey) as? WeakWrapper,
                let wrapper = weakWrapper.value else {
            // Not our text input, call original and return
            if let originalIMP = originalPasteIMP {
              typealias OriginalIMP = @convention(c) (AnyObject, Selector, Any?) -> Void
              let originalFunction = unsafeBitCast(originalIMP, to: OriginalIMP.self)
              originalFunction(object, pasteSelector, sender)
            }
            return
          }
          
          let pasteboard = UIPasteboard.general
          
          // CRITICAL: Check for GIFs FIRST using explicit type queries
          // This gets raw data without triggering UIImage conversion
          var hasGIF = false
          for gifType in wrapper.gifTypes {
            if let gifData = pasteboard.data(forPasteboardType: gifType), !gifData.isEmpty {
              hasGIF = true
              break
            }
          }
          
          // Also check items for GIF data (but be careful not to trigger conversion)
          if !hasGIF {
            for item in pasteboard.items {
              for (key, _) in item {
                if wrapper.gifTypes.contains(key) || key.lowercased().contains("gif") {
                  hasGIF = true
                  break
                }
              }
              if hasGIF { break }
            }
          }
          
          // If we have a GIF, process it immediately without touching hasImages
          if hasGIF {
            DispatchQueue.main.async {
              wrapper.processPasteboardContent()
            }
            return // Don't call original paste for GIFs
          }
          
          // Check for other image data (but not GIFs, already handled)
          var hasImageData = false
          for item in pasteboard.items {
            for (key, value) in item {
              // Skip GIF-related keys
              if key.lowercased().contains("gif") {
                continue
              }
              
              // Check if this looks like image data
              let isImageKey = key.contains("image") || key.contains("png") || key.contains("jpeg") ||
                key.contains("jpg") || key.contains("tiff") || key.contains("heic") ||
                key.contains("heif") || key.contains("webp")
              
              if isImageKey && (value is Data || value is UIImage) {
                hasImageData = true
                break
              } else if value is UIImage {
                hasImageData = true
                break
              }
            }
            if hasImageData { break }
          }
          
          // If we found potential image data, process it
          if hasImageData {
            DispatchQueue.main.async {
              wrapper.processPasteboardContent()
            }
            return // Don't call original paste for images
          }
          
          // Fallback: check hasImages only if no image data found in items
          // This is safer as we've already checked for GIFs above
          if pasteboard.hasImages || wrapper.hasPasteboardData(forAnyTypeIn: wrapper.webpTypes, pasteboard: pasteboard) {
            DispatchQueue.main.async {
              wrapper.processPasteboardContent()
            }
            return // Don't call original paste for images
          }
          
          // Handle text - call original paste first, then notify
          if let originalIMP = originalPasteIMP {
            typealias OriginalIMP = @convention(c) (AnyObject, Selector, Any?) -> Void
            let originalFunction = unsafeBitCast(originalIMP, to: OriginalIMP.self)
            originalFunction(object, pasteSelector, sender)
          }
          
          // Notify about text paste
          if pasteboard.hasStrings {
            DispatchQueue.main.async {
              wrapper.processTextPaste()
            }
          }
        }
        
        let blockIMP = imp_implementationWithBlock(unsafeBitCast(swizzledImplementation, to: AnyObject.self))
        let types = method_getTypeEncoding(originalMethod)
        
        if class_addMethod(viewClass, swizzledPasteSelector, blockIMP, types) {
          if let swizzledMethod = class_getInstanceMethod(viewClass, swizzledPasteSelector) {
            method_exchangeImplementations(originalMethod, swizzledMethod)
            didSwizzle = true
          }
        }
      }
    }

    if #available(iOS 18.0, *),
       let originalMethod = class_getInstanceMethod(viewClass, NSSelectorFromString("insertAdaptiveImageGlyph:replacementRange:")) {
      let adaptiveGlyphSelector = NSSelectorFromString("insertAdaptiveImageGlyph:replacementRange:")
      let swizzledAdaptiveGlyphSelector = NSSelectorFromString("_expoPasteInput_insertAdaptiveImageGlyph:replacementRange:")
      let originalAdaptiveGlyphIMP = method_getImplementation(originalMethod)

      if class_getInstanceMethod(viewClass, swizzledAdaptiveGlyphSelector) == nil {
        let swizzledImplementation: @convention(block) (AnyObject, AnyObject, UITextRange?) -> Void = { object, glyphObject, replacementRange in
          guard let weakWrapper = objc_getAssociatedObject(object, &textInputWrapperKey) as? WeakWrapper,
                let wrapper = weakWrapper.value else {
            typealias OriginalIMP = @convention(c) (AnyObject, Selector, AnyObject, UITextRange?) -> Void
            let originalFunction = unsafeBitCast(originalAdaptiveGlyphIMP, to: OriginalIMP.self)
            originalFunction(object, adaptiveGlyphSelector, glyphObject, replacementRange)
            return
          }

          guard let adaptiveGlyph = glyphObject as? NSAdaptiveImageGlyph else {
            typealias OriginalIMP = @convention(c) (AnyObject, Selector, AnyObject, UITextRange?) -> Void
            let originalFunction = unsafeBitCast(originalAdaptiveGlyphIMP, to: OriginalIMP.self)
            originalFunction(object, adaptiveGlyphSelector, glyphObject, replacementRange)
            return
          }

          if wrapper.handleAdaptiveImageGlyphInsertion(adaptiveGlyph) {
            return
          }

          typealias OriginalIMP = @convention(c) (AnyObject, Selector, AnyObject, UITextRange?) -> Void
          let originalFunction = unsafeBitCast(originalAdaptiveGlyphIMP, to: OriginalIMP.self)
          originalFunction(object, adaptiveGlyphSelector, glyphObject, replacementRange)
        }

        let blockIMP = imp_implementationWithBlock(unsafeBitCast(swizzledImplementation, to: AnyObject.self))
        let types = method_getTypeEncoding(originalMethod)

        if class_addMethod(viewClass, swizzledAdaptiveGlyphSelector, blockIMP, types) {
          if let swizzledMethod = class_getInstanceMethod(viewClass, swizzledAdaptiveGlyphSelector) {
            method_exchangeImplementations(originalMethod, swizzledMethod)
            didSwizzle = true
          }
        }
      }
    }
    
    // Mark this class as swizzled only if we successfully swizzled at least one method
    // (once per class, never unswizzle)
    if didSwizzle {
      ExpoPasteInputView.swizzledClasses.insert(className)
    }
  }
  
  private func findTextInputInView(_ view: UIView) -> UIView? {
    if view is TextInputEnhanceable {
      return view
    }
    
    for subview in view.subviews {
      if let found = findTextInputInView(subview) {
        return found
      }
    }
    
    return nil
  }

  @available(iOS 18.0, *)
  private func currentAdaptiveImageGlyphSupport(for view: UIView) -> Bool? {
    if let textView = view as? UITextView {
      return textView.supportsAdaptiveImageGlyph
    }

    if let textField = view as? UITextField {
      return textField.supportsAdaptiveImageGlyph
    }

    return nil
  }

  @available(iOS 18.0, *)
  private func setAdaptiveImageGlyphSupport(_ isEnabled: Bool, for view: UIView) {
    if let textView = view as? UITextView {
      textView.supportsAdaptiveImageGlyph = isEnabled
      return
    }

    if let textField = view as? UITextField {
      textField.supportsAdaptiveImageGlyph = isEnabled
    }
  }

  private func shouldExposePasteAction(for object: AnyObject) -> Bool {
    if let textView = object as? UITextView {
      return textView.isEditable &&
        textView.isSelectable &&
        textView.isUserInteractionEnabled &&
        !textView.isHidden &&
        textView.alpha > 0.01
    }

    if let textField = object as? UITextField {
      return textField.isEnabled &&
        textField.isUserInteractionEnabled &&
        !textField.isHidden &&
        textField.alpha > 0.01
    }

    if let view = object as? UIView {
      return view.isUserInteractionEnabled &&
        !view.isHidden &&
        view.alpha > 0.01
    }

    return false
  }

  private func observeTextViewChanges(for textView: UITextView) {
    if observedTextView === textView, textDidChangeObserver != nil {
      return
    }

    stopObservingTextView()
    observedTextView = textView

    textDidChangeObserver = NotificationCenter.default.addObserver(
      forName: UITextView.textDidChangeNotification,
      object: textView,
      queue: .main
    ) { [weak self, weak textView] _ in
      guard let self, let textView else {
        return
      }

      self.handleTextViewDidChange(textView)
    }
  }

  private func stopObservingTextView() {
    if let observer = textDidChangeObserver {
      NotificationCenter.default.removeObserver(observer)
      textDidChangeObserver = nil
    }

    observedTextView = nil
  }

  private func handleTextViewDidChange(_ textView: UITextView) {
    guard observedTextView === textView, !isSanitizingAttachments else {
      return
    }

    let attributedText = textView.attributedText ?? NSAttributedString(string: textView.text ?? "")
    guard attributedText.length > 0 else {
      return
    }

    var attachmentRanges: [NSRange] = []
    var mediaPayloads: [MediaPayload] = []

    // Only track ranges for attachments we successfully extract a real payload
    // from. Attachments without a payload (e.g. iOS dictation placeholders)
    // are left alone — sanitizing them would delete characters the system
    // manages itself, and emitting "unsupported" would raise a spurious error.
    attributedText.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributedText.length), options: []) { value, range, _ in
      guard let attachment = value as? NSTextAttachment else {
        return
      }

      if let payload = self.extractMediaPayload(from: attachment, textView: textView, range: range) {
        attachmentRanges.append(range)
        mediaPayloads.append(payload)
      }
    }

    if #available(iOS 18.0, *) {
      attributedText.enumerateAttribute(.adaptiveImageGlyph, in: NSRange(location: 0, length: attributedText.length), options: []) { value, range, _ in
        guard let adaptiveGlyph = value as? NSAdaptiveImageGlyph else {
          return
        }

        if let payload = self.extractMediaPayload(from: adaptiveGlyph) {
          attachmentRanges.append(range)
          mediaPayloads.append(payload)
        }
      }
    }

    attachmentRanges = uniqueRanges(attachmentRanges)

    guard !mediaPayloads.isEmpty else {
      return
    }

    sanitizeAttachments(in: textView, ranges: attachmentRanges)

    emitImagesAsync(for: mediaPayloads)
  }

  private func emitImagesAsync(for payloads: [MediaPayload]) {
    mediaProcessingQueue.async { [weak self] in
      guard let self else {
        return
      }

      let uris = self.temporaryFileURIs(for: payloads)

      DispatchQueue.main.async { [weak self] in
        guard let self else {
          return
        }

        if uris.isEmpty {
          self.handleUnsupportedPaste()
          return
        }

        self.emitImages(uris: uris)
      }
    }
  }

  private func sanitizeAttachments(in textView: UITextView, ranges: [NSRange]) {
    let sanitizedText = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString(string: textView.text ?? ""))
    let originalSelectedRange = textView.selectedRange

    for range in ranges.reversed() {
      sanitizedText.deleteCharacters(in: range)
    }

    isSanitizingAttachments = true
    defer {
      isSanitizingAttachments = false
    }

    textView.attributedText = sanitizedText

    guard originalSelectedRange.location != NSNotFound else {
      return
    }

    textView.selectedRange = adjustedSelectedRange(
      from: originalSelectedRange,
      removing: ranges,
      finalLength: sanitizedText.length
    )
  }

  private func adjustedSelectedRange(from selectedRange: NSRange, removing ranges: [NSRange], finalLength: Int) -> NSRange {
    let start = adjustedLocation(selectedRange.location, removing: ranges)
    let end = adjustedLocation(selectedRange.location + selectedRange.length, removing: ranges)
    let clampedStart = min(max(0, start), finalLength)
    let clampedEnd = min(max(clampedStart, end), finalLength)

    return NSRange(location: clampedStart, length: clampedEnd - clampedStart)
  }

  private func adjustedLocation(_ location: Int, removing ranges: [NSRange]) -> Int {
    var adjustedLocation = location

    for range in ranges {
      let rangeEnd = NSMaxRange(range)

      if location >= rangeEnd {
        adjustedLocation -= range.length
        continue
      }

      if location >= range.location {
        adjustedLocation = min(adjustedLocation, range.location)
        break
      }
    }

    return max(0, adjustedLocation)
  }

  private func uniqueRanges(_ ranges: [NSRange]) -> [NSRange] {
    var seen = Set<String>()
    var uniqueRanges: [NSRange] = []

    for range in ranges.sorted(by: { lhs, rhs in
      if lhs.location == rhs.location {
        return lhs.length < rhs.length
      }
      return lhs.location < rhs.location
    }) {
      let key = "\(range.location):\(range.length)"
      if seen.insert(key).inserted {
        uniqueRanges.append(range)
      }
    }

    return uniqueRanges
  }

  private func extractMediaPayload(from attachment: NSTextAttachment, textView: UITextView, range: NSRange) -> MediaPayload? {
    // Only accept attachments that carry real image payloads. We intentionally
    // do not fall back to `image(forBounds:)` or rendering the text view's
    // hierarchy, because system-inserted attachments (e.g. the iOS dictation
    // placeholder) draw themselves via those paths and would cause us to
    // emit a screenshot of the composer as a "pasted image".
    if let fileWrapperData = attachment.fileWrapper?.regularFileContents,
       let payload = extractMediaPayload(fromData: fileWrapperData) {
      return payload
    }

    if let contents = attachment.contents,
       let payload = extractMediaPayload(fromData: contents) {
      return payload
    }

    if let image = attachment.image,
       image.size.width > 0,
       image.size.height > 0 {
      return .image(image)
    }

    return nil
  }

  @available(iOS 18.0, *)
  private func extractMediaPayload(from adaptiveGlyph: NSAdaptiveImageGlyph) -> MediaPayload? {
    extractMediaPayload(fromData: adaptiveGlyph.imageContent)
  }

  private func extractMediaPayload(fromData data: Data) -> MediaPayload? {
    guard !data.isEmpty else {
      return nil
    }

    if isGIFData(data) {
      return .gif(data)
    }

    return .imageData(data)
  }

  @available(iOS 18.0, *)
  private func handleAdaptiveImageGlyphInsertion(_ adaptiveGlyph: NSAdaptiveImageGlyph) -> Bool {
    guard let payload = extractMediaPayload(from: adaptiveGlyph) else {
      handleUnsupportedPaste()
      return true
    }

    emitImagesAsync(for: [payload])
    return true
  }
  
  private func processPasteboardContent() {
    // This method is only called for image pastes
    let pasteboard = UIPasteboard.general
    
    let staticImageTypes = [
      "public.png",
      "public.jpeg",
      "public.tiff",
      "public.heic",
      "public.heif",
      "public.image",
      "org.webmproject.webp",
      "public.webp",
      "image/webp"
    ]
    
    var gifDataItems: [Data] = []
    var staticImagePayloads: [MediaPayload] = []
    var processedGifHashes = Set<Int>()
    
    // Get all items once to ensure consistent access
    let items = pasteboard.items
    let itemCount = items.count
    
    // Process each pasteboard item individually
    // This ensures correct handling of mixed GIF and static image pastes
    for itemIndex in 0..<itemCount {
      let item = items[itemIndex]
      let itemKeys = Set(item.keys) // Types available for THIS specific item
      let singleItemSet = IndexSet(integer: itemIndex)
      
      var itemIsGif = false
      var gifDataForItem: Data? = nil
      
      // ===== STEP 1: Check if this item is a GIF =====
      // Check if any of this item's keys indicate it's a GIF
      let itemGifKeys = itemKeys.filter { key in
        gifTypes.contains(key) || key.lowercased().contains("gif")
      }
      
      // Try to extract GIF data from this item
      for gifKey in itemGifKeys {
        // Method 1: Try to get data from the item dictionary directly
        if let gifData = item[gifKey] as? Data, !gifData.isEmpty, isGIFData(gifData) {
          gifDataForItem = gifData
          itemIsGif = true
          break
        }
        
        // Method 2: Use pasteboard API for this specific item
        if let dataArray = pasteboard.data(forPasteboardType: gifKey, inItemSet: singleItemSet),
           let gifData = dataArray.first,
           !gifData.isEmpty, isGIFData(gifData) {
          gifDataForItem = gifData
          itemIsGif = true
          break
        }
      }
      
      // If found a GIF, add it and continue to next item
      if itemIsGif, let gifData = gifDataForItem {
        let hash = gifData.hashValue
        if !processedGifHashes.contains(hash) {
          gifDataItems.append(gifData)
          processedGifHashes.insert(hash)
        }
        continue // Skip static image extraction for this item
      }
      
      // ===== STEP 2: This item is NOT a GIF - extract static image =====
      var extractedPayload: MediaPayload? = nil
      
      // Try each static image type in order of preference (only if this item has that type)
      for imageType in staticImageTypes {
        guard itemKeys.contains(imageType) else { continue }
        
        // Method 1: Try item dictionary directly
        if let imageData = item[imageType] as? Data, !imageData.isEmpty, !isGIFData(imageData) {
          extractedPayload = .imageData(imageData)
          break
        }
        
        // Method 2: Use pasteboard API
        if extractedPayload == nil,
           let dataArray = pasteboard.data(forPasteboardType: imageType, inItemSet: singleItemSet),
           let imageData = dataArray.first,
           !imageData.isEmpty, !isGIFData(imageData) {
          extractedPayload = .imageData(imageData)
          break
        }
      }
      
      // Fallback: Try any non-GIF image data from the item dictionary
      if extractedPayload == nil {
        // Sort keys to have consistent ordering (prefer png, jpeg, then others)
        let sortedKeys = itemKeys.sorted { k1, k2 in
          let priority1 = k1.contains("png") ? 0 : (k1.contains("jpeg") || k1.contains("jpg") ? 1 : 2)
          let priority2 = k2.contains("png") ? 0 : (k2.contains("jpeg") || k2.contains("jpg") ? 1 : 2)
          return priority1 < priority2
        }
        
        for key in sortedKeys {
          // Skip GIF-related keys
          if key.lowercased().contains("gif") {
            continue
          }
          
          // Try Data
          if let imageData = item[key] as? Data, imageData.count >= 6, !isGIFData(imageData) {
            extractedPayload = .imageData(imageData)
            break
          }
          
          // Try UIImage
          if let image = item[key] as? UIImage, image.size.width > 0, image.size.height > 0 {
            extractedPayload = .image(image)
            break
          }
        }
      }
      
      // Add the extracted static image
      if let payload = extractedPayload {
        staticImagePayloads.append(payload)
      }
    }
    
    // Final fallback: If nothing was extracted at all, try pasteboard.image
    if staticImagePayloads.isEmpty && gifDataItems.isEmpty, let image = pasteboard.image {
      staticImagePayloads.append(.image(image))
    }
    
    let mediaPayloads = gifDataItems.map { MediaPayload.gif($0) } + staticImagePayloads

    if mediaPayloads.isEmpty {
      // If we have neither GIFs nor images, treat as unsupported
      handleUnsupportedPaste()
      return
    }

    emitImagesAsync(for: mediaPayloads)
  }
  
  /// Detects if the given data is a GIF by checking for GIF87a or GIF89a header
  private func isGIFData(_ data: Data) -> Bool {
    guard data.count >= 6 else { return false }
    
    // Check for GIF signature: "GIF87a" or "GIF89a"
    let gif87aSignature: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x37, 0x61] // "GIF87a"
    let gif89aSignature: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61] // "GIF89a"
    
    let header = data.prefix(6)
    let headerBytes = [UInt8](header)
    
    return headerBytes == gif87aSignature || headerBytes == gif89aSignature
  }
  
  /// Safely creates a UIImage from data, validating it first to prevent ImageIO errors
  private func safeCreateImage(from data: Data) -> UIImage? {
    guard data.count > 0 else { return nil }
    
    // Use ImageIO to validate the data before creating UIImage
    // This prevents ImageIO errors from corrupted or invalid image data
    guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
      return nil
    }
    
    // Check if the image source has at least one image
    guard CGImageSourceGetCount(imageSource) > 0 else {
      return nil
    }
    
    // Create UIImage from the original data so imageOrientation from metadata is preserved.
    guard let image = UIImage(data: data) else {
      return nil
    }
    
    // Validate the image has valid dimensions
    guard image.size.width > 0 && image.size.height > 0 else {
      return nil
    }
    
    return image
  }
  
  private func processTextPaste() {
    // This method is only called for text pastes
    let pasteboard = UIPasteboard.general
    
    // Check for text using pasteboard.string
    if let text = pasteboard.string, !text.isEmpty {
      handleTextPaste(text)
      return
    }
    
    // No text found - don't trigger unsupported, just ignore
  }
  
  private func handleTextPaste(_ text: String) {
    onPaste([
      "type": "text",
      "value": text
    ])
  }
  
  private func handleUnsupportedPaste() {
    onPaste([
      "type": "unsupported"
    ])
  }

  private func emitImages(uris: [String]) {
    guard !uris.isEmpty else {
      return
    }

    onPaste([
      "type": "images",
      "uris": uris
    ])
  }

  private func temporaryFileURIs(for payloads: [MediaPayload]) -> [String] {
    var uris: [String] = []

    for payload in payloads {
      switch payload {
      case .gif(let data):
        if let uri = writeTemporaryGIF(data) {
          uris.append(uri)
        }
      case .imageData(let data):
        if let uri = writeTemporaryImageData(data) {
          uris.append(uri)
        }
      case .image(let image):
        if let uri = writeTemporaryImage(image) {
          uris.append(uri)
        }
      }
    }

    return uris
  }

  private func writeTemporaryGIF(_ data: Data) -> String? {
    guard !data.isEmpty else {
      return nil
    }

    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("gif")

    do {
      try data.write(to: fileURL)
      return fileURL.absoluteString
    } catch {
      return nil
    }
  }

  private func writeTemporaryImageData(_ data: Data) -> String? {
    guard let image = safeCreateImage(from: data) else {
      return nil
    }

    return writeTemporaryImage(image)
  }

  private func writeTemporaryImage(_ image: UIImage) -> String? {
    let normalizedImage = image.normalizedOrientation()
    let hasAlpha = normalizedImage.hasAlpha

    let imageData: Data?
    if hasAlpha {
      imageData = normalizedImage.pngData()
    } else {
      imageData = normalizedImage.jpegData(compressionQuality: 0.8)
    }

    guard let imageData else {
      return nil
    }

    let fileExtension = hasAlpha ? "png" : "jpg"
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(fileExtension)

    do {
      try imageData.write(to: fileURL)
      return fileURL.absoluteString
    } catch {
      return nil
    }
  }
  
  deinit {
    stopMonitoring()
    stopObservingTextView()
  }

  private func hasPasteboardData(forAnyTypeIn types: Set<String>, pasteboard: UIPasteboard) -> Bool {
    for type in types {
      if let data = pasteboard.data(forPasteboardType: type), !data.isEmpty {
        return true
      }
    }
    return false
  }
}

extension UIImage {
  var hasAlpha: Bool {
    guard let cgImage = self.cgImage else { return false }
    let alphaInfo = cgImage.alphaInfo
    return alphaInfo != .none && alphaInfo != .noneSkipFirst && alphaInfo != .noneSkipLast
  }

  func normalizedOrientation() -> UIImage {
    guard imageOrientation != .up else { return self }
    guard size.width > 0 && size.height > 0 else { return self }

    let format = UIGraphicsImageRendererFormat.default()
    format.scale = scale
    format.opaque = !hasAlpha

    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      draw(in: CGRect(origin: .zero, size: size))
    }
  }
}
