import ExpoModulesCore

public class ExpoPasteInputModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoPasteInput")
    
    View(ExpoPasteInputView.self) {
      Events("onPaste")
    }
  }
}