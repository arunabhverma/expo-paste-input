import * as React from 'react';

import { ExpoPasteInputViewProps } from './ExpoPasteInput.types';

export default function ExpoPasteInputView(props: ExpoPasteInputViewProps) {
  return (
    <div>
      <iframe
        style={{ flex: 1 }}
        src={props.url}
        onLoad={() => props.onLoad({ nativeEvent: { url: props.url } })}
      />
    </div>
  );
}
