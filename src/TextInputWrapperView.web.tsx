import * as React from "react";
import { View } from "react-native";
import { TextInputWrapperViewProps } from "./TextInputWrapper.types";

export const TextInputWrapperView = React.forwardRef<
  View,
  TextInputWrapperViewProps
>((props, ref) => {
  const { onPaste, ...viewProps } = props;
  return (
    <View ref={ref} {...viewProps}>
      {props.children}
    </View>
  );
});

TextInputWrapperView.displayName = "TextInputWrapperView";
