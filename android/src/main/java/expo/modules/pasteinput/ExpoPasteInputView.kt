package expo.modules.pasteinput

import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.view.ActionMode
import android.widget.EditText
import androidx.core.view.ContentInfoCompat
import androidx.core.view.OnReceiveContentListener
import androidx.core.view.ViewCompat
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView
import java.io.File
import java.io.FileOutputStream

class ExpoPasteInputView(context: Context, appContext: AppContext) : ExpoView(context, appContext) {
  private val onPaste by EventDispatcher()
  private var textInputView: EditText? = null
  private var isMonitoring: Boolean = false
  private var contentListener: OnReceiveContentListener? = null
  private var originalSelectionActionModeCallback: ActionMode.Callback? = null
  private var originalInsertionActionModeCallback: ActionMode.Callback? = null
  private var customSelectionActionModeCallback: ActionMode.Callback? = null
  private var customInsertionActionModeCallback: ActionMode.Callback? = null
  private var suppressOnReceiveContentUntilMs: Long = 0L
  
  private data class ClipboardPayload(
    val imageUris: List<Uri>,
    val gifUris: List<Uri>,
    val textContent: String?
  ) {
    val hasImages: Boolean
      get() = imageUris.isNotEmpty() || gifUris.isNotEmpty()
  }
  
  init {
    // Make view completely transparent and non-interactive - only monitor paste events
    setBackgroundColor(android.graphics.Color.TRANSPARENT)
    isClickable = false
    isFocusable = false
    isFocusableInTouchMode = false
    isEnabled = true // Keep enabled so children can receive events
    
    // Enable monitoring when view is attached
    addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
      override fun onViewAttachedToWindow(v: View) {
        startMonitoring()
      }
      
      override fun onViewDetachedFromWindow(v: View) {
        stopMonitoring()
      }
    })
  }

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    // Let the wrapper resolve its own size first, then size children to the
    // resolved content box so wrapped RN inputs can fill like a normal container.
    super.onMeasure(widthMeasureSpec, heightMeasureSpec)

    val availableWidth = (measuredWidth - paddingLeft - paddingRight).coerceAtLeast(0)
    val availableHeight = (measuredHeight - paddingTop - paddingBottom).coerceAtLeast(0)

    val childWidthSpec = MeasureSpec.makeMeasureSpec(availableWidth, MeasureSpec.EXACTLY)
    val childHeightSpec = MeasureSpec.makeMeasureSpec(availableHeight, MeasureSpec.EXACTLY)

    for (i in 0 until childCount) {
      val child = getChildAt(i)
      if (child.visibility != View.GONE) {
        child.measure(childWidthSpec, childHeightSpec)
      }
    }
  }

  override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
    val left = paddingLeft
    val top = paddingTop
    val right = (r - l - paddingRight).coerceAtLeast(left)
    val bottom = (b - t - paddingBottom).coerceAtLeast(top)

    for (i in 0 until childCount) {
      val child = getChildAt(i)
      if (child.visibility != View.GONE) {
        child.layout(left, top, right, bottom)
      }
    }
  }

  override fun onViewAdded(child: View?) {
    super.onViewAdded(child)
    // Let default container sizing recalculate after RN inserts a child.
    requestLayout()
    invalidate()

    // Re-scan for text input when a new child is added
    if (!isMonitoring) {
      startMonitoring()
    } else {
      // If already monitoring, check if the new child is a text input
      val newTextInput = findTextInputInView(child)
      if (newTextInput != null && newTextInput != textInputView) {
        // Found a different text input, switch to it
        stopMonitoring()
        startMonitoring()
      }
    }
  }
  
  private fun startMonitoring() {
    if (isMonitoring) return
    
    // Find TextInput (EditText) in view hierarchy
    val foundTextInput = findTextInputInView(this) as? EditText
    
    if (foundTextInput != null) {
      textInputView = foundTextInput
      isMonitoring = true
      setupPasteHandling(foundTextInput)
    }
  }
  
  private fun stopMonitoring() {
    if (!isMonitoring) return
    
    val editText = textInputView
    if (editText != null) {
      cleanupPasteHandling(editText)
    }
    
    isMonitoring = false
    textInputView = null
    contentListener = null
    originalSelectionActionModeCallback = null
    originalInsertionActionModeCallback = null
    customSelectionActionModeCallback = null
    customInsertionActionModeCallback = null
  }
  
  private fun setupPasteHandling(editText: EditText) {
    // Set up OnReceiveContentListener for Android 12+ (API 31+)
    // This is the primary mechanism for handling image pastes
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      contentListener = createContentListener()
      ViewCompat.setOnReceiveContentListener(
        editText,
        arrayOf("image/*", "text/plain"),
        contentListener!!
      )
    }
    
    // Intercept paste from context menu to prevent toast
    enhanceOnTextContextMenuItem(editText)
  }
  
  private fun cleanupPasteHandling(editText: EditText) {
    // Remove OnReceiveContentListener
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && contentListener != null) {
      ViewCompat.setOnReceiveContentListener(editText, null, null)
    }
    
    // Restore original ActionMode.Callback
    if (customSelectionActionModeCallback != null) {
      editText.customSelectionActionModeCallback = originalSelectionActionModeCallback
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && customInsertionActionModeCallback != null) {
      editText.customInsertionActionModeCallback = originalInsertionActionModeCallback
    }
  }
  
  private fun createContentListener(): OnReceiveContentListener {
    return OnReceiveContentListener { _, payload ->
      if (shouldSuppressOnReceiveContent()) {
        return@OnReceiveContentListener null
      }
      
      val parsed = parseClipboardPayload(payload.clip, context)
      if (parsed.hasImages) {
        processMultipleImagePaste(parsed.imageUris, parsed.gifUris)
        // Consume image content to prevent default EditText "can't paste image" UX.
        return@OnReceiveContentListener null
      }
      
      if (!parsed.textContent.isNullOrEmpty()) {
        handleTextPaste(parsed.textContent)
        // Keep native text insertion behavior.
        return@OnReceiveContentListener payload
      }
      
      handleUnsupportedPaste()
      return@OnReceiveContentListener payload
    }
  }
  
  private fun enhanceOnTextContextMenuItem(editText: EditText) {
    // Intercept paste from context menu to prevent toast
    // This must happen BEFORE Android tries to paste, otherwise the toast appears
    try {
      // Store original callbacks if they exist
      originalSelectionActionModeCallback = editText.customSelectionActionModeCallback
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
        originalInsertionActionModeCallback = editText.customInsertionActionModeCallback
      }
      
      // Set up custom callbacks to intercept paste from both selection and insertion menus.
      customSelectionActionModeCallback = createActionModeCallback(
        editText = editText,
        originalCallback = originalSelectionActionModeCallback
      )
      editText.customSelectionActionModeCallback = customSelectionActionModeCallback

      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
        customInsertionActionModeCallback = createActionModeCallback(
          editText = editText,
          originalCallback = originalInsertionActionModeCallback
        )
        editText.customInsertionActionModeCallback = customInsertionActionModeCallback
      }
      
    } catch (e: Exception) {
      // If ActionMode.Callback approach fails, we'll rely on OnReceiveContentListener
      // which should still work but may show the toast briefly
    }
  }

  private fun createActionModeCallback(
    editText: EditText,
    originalCallback: ActionMode.Callback?
  ): ActionMode.Callback {
    return object : ActionMode.Callback {
        override fun onCreateActionMode(mode: ActionMode?, menu: android.view.Menu?): Boolean {
          // Delegate to original callback if it exists
          return originalCallback?.onCreateActionMode(mode, menu) ?: true
        }
        
        override fun onPrepareActionMode(mode: ActionMode?, menu: android.view.Menu?): Boolean {
          // Delegate to original callback if it exists
          return originalCallback?.onPrepareActionMode(mode, menu) ?: false
        }
        
        override fun onActionItemClicked(mode: ActionMode?, item: android.view.MenuItem?): Boolean {
          if (item?.itemId == android.R.id.paste) {
            return handlePasteFromActionMode(editText, mode, item, originalCallback)
          }
          
          // For other actions, delegate to original callback or return false
          return originalCallback?.onActionItemClicked(mode, item) ?: false
        }
        
        override fun onDestroyActionMode(mode: ActionMode?) {
          // Delegate to original callback if it exists
          originalCallback?.onDestroyActionMode(mode)
        }
      }
  }
  
  private fun handlePasteFromActionMode(
    editText: EditText,
    mode: ActionMode?,
    item: android.view.MenuItem,
    originalCallback: ActionMode.Callback?
  ): Boolean {
    val clipboard = editText.context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    val parsed = parseClipboardPayload(clipboard.primaryClip, editText.context)
    
    if (parsed.hasImages) {
      markSuppressOnReceiveContent()
      processMultipleImagePaste(parsed.imageUris, parsed.gifUris)
      mode?.finish()
      return true
    }
    
    val text = parsed.textContent
    if (!text.isNullOrEmpty()) {
      var handled = originalCallback?.onActionItemClicked(mode, item) ?: false
      if (!handled) {
        handled = editText.onTextContextMenuItem(item.itemId)
      }
      if (!handled) {
        insertTextAtCursor(editText, text)
        handled = true
      }
      
      if (handled) {
        // On Android < 12, ActionMode path is the only reliable callback for text.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
          handleTextPaste(text)
        }
        markSuppressOnReceiveContent()
        mode?.finish()
        return true
      }
    }
    
    handleUnsupportedPaste()
    mode?.finish()
    return true
  }

  private fun parseClipboardPayload(
    clipData: android.content.ClipData?,
    sourceContext: Context
  ): ClipboardPayload {
    if (clipData == null || clipData.itemCount <= 0) {
      return ClipboardPayload(emptyList(), emptyList(), null)
    }
    
    val imageUris = mutableListOf<Uri>()
    val gifUris = mutableListOf<Uri>()
    var textContent: String? = null
    
    for (i in 0 until clipData.itemCount) {
      val clipItem = clipData.getItemAt(i)
      val uri = clipItem.uri
      if (uri != null) {
        val mimeType = sourceContext.contentResolver.getType(uri)?.lowercase()
        if (mimeType != null && mimeType.startsWith("image/")) {
          if (mimeType == "image/gif") {
            gifUris.add(uri)
          } else {
            imageUris.add(uri)
          }
        } else if (isLikelyGifUri(uri)) {
          gifUris.add(uri)
        } else if (isLikelyImageUri(uri)) {
          imageUris.add(uri)
        }
      }
      
      if (textContent == null) {
        val text = clipItem.coerceToText(sourceContext)
        if (!text.isNullOrEmpty()) {
          textContent = text.toString()
        }
      }
    }
    
    return ClipboardPayload(
      imageUris = imageUris,
      gifUris = gifUris,
      textContent = textContent
    )
  }

  private fun isLikelyImageUri(uri: Uri): Boolean {
    val fileName = uri.lastPathSegment?.lowercase() ?: return false
    return fileName.endsWith(".png") ||
      fileName.endsWith(".jpg") ||
      fileName.endsWith(".jpeg") ||
      fileName.endsWith(".webp") ||
      fileName.endsWith(".heic") ||
      fileName.endsWith(".heif")
  }

  private fun isLikelyGifUri(uri: Uri): Boolean {
    val fileName = uri.lastPathSegment?.lowercase() ?: return false
    return fileName.endsWith(".gif")
  }

  private fun markSuppressOnReceiveContent() {
    suppressOnReceiveContentUntilMs = SystemClock.elapsedRealtime() + 500L
  }

  private fun shouldSuppressOnReceiveContent(): Boolean {
    return SystemClock.elapsedRealtime() <= suppressOnReceiveContentUntilMs
  }

  private fun insertTextAtCursor(editText: EditText, text: String) {
    val editable = editText.editableText ?: return
    val start = editText.selectionStart
    val end = editText.selectionEnd

    val replaceStart = minOf(start, end).coerceAtLeast(0)
    val replaceEnd = maxOf(start, end).coerceAtLeast(0)

    if (replaceStart <= replaceEnd && replaceEnd <= editable.length) {
      editable.replace(replaceStart, replaceEnd, text)
      val newCursor = (replaceStart + text.length).coerceAtMost(editable.length)
      editText.setSelection(newCursor)
    } else {
      editable.append(text)
      editText.setSelection(editable.length)
    }
  }
  
  private fun findTextInputInView(view: View?): View? {
    if (view == null) return null
    
    val className = view.javaClass.simpleName
    if (className.contains("ReactTextInput") || 
        className.contains("EditText") ||
        view is EditText) {
      return view
    }
    
    if (view is ViewGroup) {
      for (i in 0 until view.childCount) {
        val child = view.getChildAt(i)
        val found = findTextInputInView(child)
        if (found != null) {
          return found
        }
      }
    }
    
    return null
  }
  
  internal fun processMultipleImagePaste(imageUris: List<Uri>, gifUris: List<Uri> = emptyList()) {
    try {
      val filePaths = mutableListOf<String>()
      
      // Process GIFs first - copy them directly without decoding
      for (gifUri in gifUris) {
        val gifPath = copyGifFile(gifUri)
        if (gifPath != null) {
          filePaths.add(gifPath)
        }
      }
      
      // Process regular images - decode and compress
      for (uri in imageUris) {
        val inputStream = context.contentResolver.openInputStream(uri) ?: continue
        
        // Use try-with-resources equivalent (use block) to ensure stream is closed
        inputStream.use { stream ->
          val bitmap = BitmapFactory.decodeStream(stream)
          
          if (bitmap == null) {
            return@use // Skip this image if we can't decode it
          }
          
          // Save to cache directory
          val cacheDir = context.cacheDir
          val usePng = bitmap.hasAlpha()
          val fileExtension = if (usePng) "png" else "jpg"
          // Use UUID-like approach for better uniqueness: timestamp + counter
          val fileName = "${System.currentTimeMillis()}_${filePaths.size}.$fileExtension"
          val file = File(cacheDir, fileName)
          
          FileOutputStream(file).use { outputStream ->
            if (usePng) {
              bitmap.compress(Bitmap.CompressFormat.PNG, 100, outputStream)
            } else {
              bitmap.compress(Bitmap.CompressFormat.JPEG, 80, outputStream)
            }
            outputStream.flush()
          }
          
          val filePath = "file://${file.absolutePath}"
          filePaths.add(filePath)
        }
      }
      
      if (filePaths.isEmpty()) {
        handleUnsupportedPaste()
        return
      }
      
      // Always use images format with array, even for single image
      onPaste(mapOf(
        "type" to "images",
        "uris" to filePaths
      ))
    } catch (e: Exception) {
      handleUnsupportedPaste()
    }
  }
  
  private fun copyGifFile(uri: Uri): String? {
    return try {
      val inputStream = context.contentResolver.openInputStream(uri) ?: return null
      
      // Save to cache directory
      val cacheDir = context.cacheDir
      // Use timestamp + counter for better uniqueness instead of random
      val fileName = "${System.currentTimeMillis()}_${System.nanoTime()}.gif"
      val file = File(cacheDir, fileName)
      
      inputStream.use { input ->
        FileOutputStream(file).use { output ->
          input.copyTo(output)
          output.flush()
        }
      }
      
      "file://${file.absolutePath}"
    } catch (e: Exception) {
      null
    }
  }
  
  private fun handleTextPaste(text: String) {
    onPaste(mapOf(
      "type" to "text",
      "value" to text
    ))
  }
  
  private fun handleUnsupportedPaste() {
    onPaste(mapOf(
      "type" to "unsupported"
    ))
  }
}
