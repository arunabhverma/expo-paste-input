# TextInputWrapper

A native Expo module for cross-platform paste event handling in React Native TextInput components.

## Demo

| iOS                                                                                             | Android                                                                                         |
| ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| <video src="https://github.com/user-attachments/assets/b54b15ac-5b98-4dc7-84d7-2e7d48e53e24" /> | <video src="https://github.com/user-attachments/assets/4d709a2c-2dca-431d-8972-05f01b7e5276" /> |

## Overview

This is **not a published npm package**. This is the exact production-ready module used inside a real app. If you want to use it, copy the `modules/text-input-wrapper` folder into your Expo project and run it.

### What it does

- Intercepts paste events on TextInput components
- Handles pasted text and images consistently across iOS and Android
- Supports pasting multiple images, including GIFs
- Returns file URIs for pasted images that you can use directly

### Paste event payload

```typescript
type PasteEventPayload =
  | { type: "text"; value: string }
  | { type: "images"; uris: string[] }
  | { type: "unsupported" };
```

## How it works

The module wraps a TextInput and intercepts paste events at the native level before they reach the default handler.

### iOS

On iOS, the module uses method swizzling to intercept `paste(_:)` on the underlying `UITextField`/`UITextView`. When a paste is detected:

- For **images**: The paste is intercepted, images are extracted from `UIPasteboard`, saved to temp files, and URIs are sent to JavaScript. GIFs are preserved as-is.
- For **text**: The original paste proceeds normally, and the pasted text is forwarded to JavaScript.

The wrapper view is transparent and passes through all touch events to children.

### Android

On Android, the module uses `OnReceiveContentListener` (API 31+) and a custom `ActionMode.Callback` to intercept paste events from both keyboard and context menu:

- For **images**: The paste is consumed before Android shows the "Can't add images" toast. Images are decoded, saved to cache, and URIs are sent to JavaScript.
- For **text**: The original paste proceeds normally, and the pasted text is forwarded to JavaScript.

The wrapper view is non-interactive and delegates all touch events to children.

## Usage

### 1. Copy the module

Copy the `modules/text-input-wrapper` folder into your Expo project's `modules` directory.

### 2. Run prebuild / pod install

```bash
# If using Expo prebuild
npx expo prebuild

# Or if you already have native projects
cd ios && pod install
```

### 3. Import and use

Wrap your TextInput with `TextInputWrapper` and handle the `onPaste` callback:

```tsx
import {
  TextInputWrapper,
  PasteEventPayload,
} from "@/modules/text-input-wrapper";
import { TextInput } from "react-native";

function MyInput() {
  const handlePaste = (payload: PasteEventPayload) => {
    if (payload.type === "images") {
      // payload.uris contains file:// URIs for each pasted image
      console.log("Pasted images:", payload.uris);
    } else if (payload.type === "text") {
      // payload.value contains the pasted text
      console.log("Pasted text:", payload.value);
    }
  };

  return (
    <TextInputWrapper onPaste={handlePaste}>
      <TextInput placeholder="Paste here..." />
    </TextInputWrapper>
  );
}
```

## Notes

- This is **intentionally not packaged as a library**
- It's meant to be copied, modified, and extended for your specific needs
- The image URIs point to temporary files — move or copy them if you need persistence
- Text paste events fire _after_ the text is inserted into the input
- Image paste events _prevent_ the default paste (since TextInput can't display images)

If you want to build a library on top of this, feel free. Please credit **Arunabh Verma** as inspiration.

## Inspiration

This project exists because of inspiration from:

- **[Fernando Rojo](https://x.com/fernandorojo)** — Inspired by his blog post how paste input is implemented in the v0 app
  - Blog + context: how native paste handling works in v0
  - 𝕏: **[How we built the v0 iOS app](https://x.com/fernandorojo/status/1993098916456452464)**
- **[v0](https://v0.dev)** — The real-world product discussed in Fernando Rojo’s writing

Their work on pushing React Native closer to native platform conventions was the catalyst for building this.

---

Built by **Arunabh Verma**  
Demo: [X post ↗](https://x.com/iamarunabh/status/1997738168247062774)
