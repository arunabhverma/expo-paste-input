# expo-paste-input

`expo-paste-input` is a lightweight wrapper around React Native `TextInput` that lets users paste images and GIFs directly from the system clipboard on **iOS and Android**.

It works at the native level to intercept paste events before React Native handles them, giving you access to pasted media as local file URIs while keeping full control over your own `TextInput` component.

See the original demo on [Twitter](https://x.com/iamarunabh/status/1997738168247062774)

| iOS | Android |
| --- | --- |
| <img src="https://github.com/user-attachments/assets/c7d9baac-b2f8-4942-9a7f-52932e65ae7e" /> | <img src="https://github.com/user-attachments/assets/6057745c-ccfc-4ca0-935d-9aa4668f22e3" /> |


---

## Features

- Paste **text, images, and multiple GIFs**
- Works on **iOS and Android**
- True wrapper around `TextInput` (bring your own input)
- No custom UI, no opinionated styles
- Returns local file URIs for pasted media
- Safe to import on Web (no crash, no-op)
- Supports Expo SwiftUI `TextField` as well.

---

## Installation

### Quick install

```bash
npx expo install expo-paste-input
````

or

```bash
yarn add expo-paste-input
```

### Rebuild the app (required)

This library uses native code, so you must rebuild.

```bash
npx expo run:ios
npx expo run:android
```

(Expo Go will not work)

---

## Usage

Wrap your `TextInput` with `TextInputWrapper`:

```tsx
import { TextInputWrapper } from "expo-paste-input";
import { TextInput } from "react-native";

export default function MyInput() {
  return (
    <TextInputWrapper
      onPaste={(payload) => {
        console.log(payload);
      }}
    >
      <TextInput placeholder="Paste here..." />
    </TextInputWrapper>
  );
}
```

---

## Props

| Prop     | Type                                   | Description                                                                        |
| -------- | -------------------------------------- | ---------------------------------------------------------------------------------- |
| children | `React.ReactElement`                   | The `TextInput` (or any custom input) you want to wrap.                            |
| onPaste  | `(payload: PasteEventPayload) => void` | Callback fired when a paste event is detected. Receives pasted text or image URIs. |

---

## Types

```ts
type PasteEventPayload =
  | { type: "text"; value: string }
  | { type: "images"; uris: string[] }
  | { type: "unsupported" };
```

* `text` → pasted text
* `images` → local file URIs (`file://...`)
* `unsupported` → anything else

---

## Why a wrapper?

This library does **not** reimplement `TextInput`.

Instead:

```tsx
<TextInputWrapper>
  <TextInput />
</TextInputWrapper>
```

This means:

* you keep full control of your input
* works with any custom TextInput
* no prop mirroring
* future-proof with RN updates

---

## Platform behavior

### iOS

* Intercepts native `paste(_:)`
* Extracts images from `UIPasteboard`
* Saves to temp files
* Preserves GIFs

### Android

* Uses `OnReceiveContentListener` + `ActionMode`
* Prevents Android "Can't paste images" toast
* Saves pasted media to cache

---

## Notes

* Image URIs are temporary files, move them if you need persistence.
* Text paste events fire after the text is inserted.
* Image paste events prevent default paste (since TextInput can't render images).
* Web is currently a no-op implementation.

---

## Inspiration

Inspired by work from:

- **Fernando Rojo** — [native paste handling in the v0 app](https://x.com/fernandorojo/status/1993098916456452464)

- **v0.dev** — real-world product pushing React Native closer to native UX

---

## License

MIT
