package expo.modules.pasteinput

import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
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
import java.io.InputStream
import java.io.IOException

class ExpoPasteInputView(context: Context, appContext: AppContext) : ExpoView(context, appContext) {
  private val onPaste by EventDispatcher()
  private var textInputView: EditText? = null
  private var isMonitoring: Boolean = false
  private var contentListener: OnReceiveContentListener? = null
  private var originalActionModeCallback: ActionMode.Callback? = null
  private var customActionModeCallback: ActionMode.Callback? = null
  
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
  
  // Pass through all touch events to children - never intercept
  override fun onInterceptTouchEvent(ev: android.view.MotionEvent?): Boolean {
    return false
  }
  
  override fun onTouchEvent(event: android.view.MotionEvent?): Boolean {
    return false
  }
  
  override fun dispatchTouchEvent(ev: android.view.MotionEvent?): Boolean {
    return super.dispatchTouchEvent(ev)
  }
  
  override fun onViewAdded(child: View?) {
    super.onViewAdded(child)
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
    originalActionModeCallback = null
    customActionModeCallback = null
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
    if (customActionModeCallback != null) {
      editText.customSelectionActionModeCallback = originalActionModeCallback
    }
  }
  
  private fun createContentListener(): OnReceiveContentListener {
    return OnReceiveContentListener { view, payload ->
      val clip = payload.clip
      val itemCount = clip.itemCount
      
      if (itemCount == 0) {
        return@OnReceiveContentListener payload
      }
      
      // Collect images and GIFs separately
      val imageUris = mutableListOf<Uri>()
      val gifUris = mutableListOf<Uri>()
      var textContent: String? = null
      
      // Process each item in the clip
      for (i in 0 until itemCount) {
        val item = clip.getItemAt(i)
        
        // Check for image URI
        val uri = item.uri
        if (uri != null) {
          val mimeType = context.contentResolver.getType(uri)
          if (mimeType != null && mimeType.startsWith("image/")) {
            // Separate GIFs from regular images
            if (mimeType == "image/gif") {
              gifUris.add(uri)
            } else {
              imageUris.add(uri)
            }
          }
        }
        
        // Check for text
        val text = item.text
        if (!text.isNullOrEmpty() && textContent == null) {
          textContent = text.toString()
        }
      }
      
      // Handle GIFs and images (always as array, even for single item)
      if (gifUris.isNotEmpty() || imageUris.isNotEmpty()) {
        processMultipleImagePaste(imageUris, gifUris)
        // Return null to completely consume the content and prevent default paste
        // This prevents Android from showing the "Can't add images" toast
        return@OnReceiveContentListener null
      }
      
      // Handle text
      if (textContent != null) {
        handleTextPaste(textContent)
        // Allow default text paste behavior
        return@OnReceiveContentListener payload
      }
      
      // Unsupported content type
      handleUnsupportedPaste()
      return@OnReceiveContentListener payload
    }
  }
  
  private fun enhanceOnTextContextMenuItem(editText: EditText) {
    // Intercept paste from context menu to prevent toast
    // This must happen BEFORE Android tries to paste, otherwise the toast appears
    try {
      // Store original callback if it exists
      originalActionModeCallback = editText.customSelectionActionModeCallback
      
      // Set up a custom ActionMode.Callback to intercept paste from context menu
      // This is the most reliable way to intercept paste before the toast appears
      customActionModeCallback = object : ActionMode.Callback {
        override fun onCreateActionMode(mode: ActionMode?, menu: android.view.Menu?): Boolean {
          // Delegate to original callback if it exists
          return originalActionModeCallback?.onCreateActionMode(mode, menu) ?: true
        }
        
        override fun onPrepareActionMode(mode: ActionMode?, menu: android.view.Menu?): Boolean {
          // Delegate to original callback if it exists
          return originalActionModeCallback?.onPrepareActionMode(mode, menu) ?: false
        }
        
        override fun onActionItemClicked(mode: ActionMode?, item: android.view.MenuItem?): Boolean {
          if (item?.itemId == android.R.id.paste) {
            // Intercept paste action
            val clipboard = editText.context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clipData = clipboard.primaryClip
            
            if (clipData != null && clipData.itemCount > 0) {
              // Collect images and GIFs separately
              val imageUris = mutableListOf<Uri>()
              val gifUris = mutableListOf<Uri>()
              var textContent: String? = null
              
              // Process all items in the clipboard
              for (i in 0 until clipData.itemCount) {
                val clipItem = clipData.getItemAt(i)
                val uri = clipItem.uri
                
                // Check if it's an image
                if (uri != null) {
                  val mimeType = editText.context.contentResolver.getType(uri)
                  if (mimeType != null && mimeType.startsWith("image/")) {
                    // Separate GIFs from regular images
                    if (mimeType == "image/gif") {
                      gifUris.add(uri)
                    } else {
                      imageUris.add(uri)
                    }
                  }
                }
                
                // Check for text (only take first text item)
                if (textContent == null) {
                  val text = clipItem.text
                  if (!text.isNullOrEmpty()) {
                    textContent = text.toString()
                  }
                }
              }
              
              // Handle GIFs and images (always as array, even for single item)
              if (gifUris.isNotEmpty() || imageUris.isNotEmpty()) {
                processMultipleImagePaste(imageUris, gifUris)
                mode?.finish()
                return true // We handled it, prevent default paste
              }
              
              // Check for text
              if (textContent != null) {
                // For text, let the normal paste logic run, then notify JS
                var handled = false
                
                // 1) Let any existing callback handle it
                if (originalActionModeCallback != null) {
                  handled = originalActionModeCallback!!.onActionItemClicked(mode, item)
                }
                
                // 2) If nothing handled it, fall back to EditText's default handler
                if (!handled && item != null) {
                  handled = editText.onTextContextMenuItem(item.itemId)
                }
                
                if (handled) {
                  handleTextPaste(textContent)
                }
                mode?.finish()
                return handled
              }
            }
          }
          
          // For other actions, delegate to original callback or return false
          return originalActionModeCallback?.onActionItemClicked(mode, item) ?: false
        }
        
        override fun onDestroyActionMode(mode: ActionMode?) {
          // Delegate to original callback if it exists
          originalActionModeCallback?.onDestroyActionMode(mode)
        }
      }
      
      editText.customSelectionActionModeCallback = customActionModeCallback
      
    } catch (e: Exception) {
      // If ActionMode.Callback approach fails, we'll rely on OnReceiveContentListener
      // which should still work but may show the toast briefly
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
          // Use UUID-like approach for better uniqueness: timestamp + counter
          val fileName = "${System.currentTimeMillis()}_${filePaths.size}.jpg"
          val file = File(cacheDir, fileName)
          
          FileOutputStream(file).use { outputStream ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, 80, outputStream)
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