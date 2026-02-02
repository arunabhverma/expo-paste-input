import { requireNativeView } from 'expo';
import * as React from 'react';

import { ExpoPasteInputViewProps } from './ExpoPasteInput.types';

const NativeView: React.ComponentType<ExpoPasteInputViewProps> =
  requireNativeView('ExpoPasteInput');

export default function ExpoPasteInputView(props: ExpoPasteInputViewProps) {
  return <NativeView {...props} />;
}
