import type { ViewProps } from "react-native";

export type PasteEventPayload =
  | { type: "text"; value: string }
  | { type: "images"; uris: string[] }
  | { type: "unsupported" };

export interface TextInputWrapperViewProps extends ViewProps {
  /**
   * Callback fired when a paste event is detected.
   * @param payload - The paste event payload containing type and content
   */
  onPaste?: (payload: PasteEventPayload) => void;

  /**
   * When true, the Paste option is hidden from the context menu and all paste
   * actions are blocked — content will not be inserted and `onPaste` will not fire.
   * @default false
   */
  disabled?: boolean;

  /**
   * Child components to wrap. Typically a TextInput component.
   */
  children?: React.ReactNode;
}
