package expo.modules.pasteinput

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class ExpoPasteInputModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("ExpoPasteInput")
    
    View(ExpoPasteInputView::class) {
      Events("onPaste")
    }
  }
}
