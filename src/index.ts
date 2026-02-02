// Reexport the native module. On web, it will be resolved to ExpoPasteInputModule.web.ts
// and on native platforms to ExpoPasteInputModule.ts
export { default } from './ExpoPasteInputModule';
export { default as ExpoPasteInputView } from './ExpoPasteInputView';
export * from  './ExpoPasteInput.types';
