import { registerWebModule, NativeModule } from 'expo';

import { ExpoPasteInputModuleEvents } from './ExpoPasteInput.types';

class ExpoPasteInputModule extends NativeModule<ExpoPasteInputModuleEvents> {
  PI = Math.PI;
  async setValueAsync(value: string): Promise<void> {
    this.emit('onChange', { value });
  }
  hello() {
    return 'Hello world! 👋';
  }
}

export default registerWebModule(ExpoPasteInputModule, 'ExpoPasteInputModule');
