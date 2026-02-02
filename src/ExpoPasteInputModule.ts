import { NativeModule, requireNativeModule } from 'expo';

import { ExpoPasteInputModuleEvents } from './ExpoPasteInput.types';

declare class ExpoPasteInputModule extends NativeModule<ExpoPasteInputModuleEvents> {
  PI: number;
  hello(): string;
  setValueAsync(value: string): Promise<void>;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<ExpoPasteInputModule>('ExpoPasteInput');
