import { Feather, Ionicons } from "@expo/vector-icons/";
import { useTheme } from "@react-navigation/native";
import Color from "color";
import { Image } from "expo-image";
import React, { useEffect, useRef, useState } from "react";
import {
  FlatList,
  LayoutChangeEvent,
  Pressable,
  StyleSheet,
  TextInput,
  View,
} from "react-native";
import Animated, {
  FadeIn,
  FadeOut,
  LayoutAnimationConfig,
  LinearTransition,
  useAnimatedStyle,
  useSharedValue,
  withSpring,
  withTiming,
  ZoomIn,
  ZoomOut,
} from "react-native-reanimated";

const AnimatedPressable = Animated.createAnimatedComponent(Pressable);

export default function Index() {
  return (
    <View style={styles.container}>
      <FlatList
        data={[]}
        renderItem={() => <View />}
        style={{ flex: 1 }}
        contentContainerStyle={{ flex: 1, flexGrow: 1 }}
      />
      <InputToolbar />
    </View>
  );
}

const InputToolbar = () => {
  const attachmentsListRef =
    useRef<FlatList<{ id: string; uri: string }>>(null);
  const theme = useTheme();
  const previousContentWidth = useRef(0);
  const scrollViewPadding = useSharedValue(0);
  const itemWidth = useSharedValue(0);
  const [attachments, setAttachments] = useState<{ id: string; uri: string }[]>(
    []
  );

  useEffect(() => {
    scrollViewPadding.value = withSpring(0);
  }, [attachments, scrollViewPadding]);

  const animatedPadding = useAnimatedStyle(() => ({
    paddingRight: scrollViewPadding.value,
  }));

  const onLayout = (e: LayoutChangeEvent) => {
    const { width } = e.nativeEvent.layout;
    console.log("width", width);
    itemWidth.value = width;
  };

  return (
    <LayoutAnimationConfig skipEntering skipExiting>
      <Animated.View
        layout={LinearTransition.springify()}
        style={[styles.inputToolbar]}
      >
        <Animated.View
          layout={LinearTransition.springify()}
          style={[
            styles.inputContainer,
            {
              backgroundColor: theme.colors.card,
              borderWidth: StyleSheet.hairlineWidth,
              borderColor: theme.colors.border,
              boxShadow: `0px 5px 5px ${Color(theme.colors.border)
                .alpha(0.5)
                .toString()}`,
            },
          ]}
        >
          {attachments.length > 0 && (
            <Animated.FlatList
              ref={attachmentsListRef}
              entering={FadeIn}
              exiting={FadeOut}
              itemLayoutAnimation={LinearTransition.springify()}
              data={attachments}
              keyExtractor={(item) => item.id}
              onContentSizeChange={(contentWidth) => {
                if (contentWidth > previousContentWidth.current) {
                  attachmentsListRef.current?.scrollToEnd();
                }
                previousContentWidth.current = contentWidth;
              }}
              horizontal
              keyboardShouldPersistTaps="handled"
              showsHorizontalScrollIndicator={false}
              renderItem={({ item, index }) => (
                <Animated.View
                  onLayout={onLayout}
                  entering={fadeZoomIn}
                  exiting={fadeZoomOut}
                  style={{
                    marginTop: 10,
                    marginRight: 10,
                    marginBottom: 10,
                    marginLeft: index === 0 ? 10 : 0,
                  }}
                >
                  <DeleteButton
                    onPress={() => {
                      const isLastItem = index === attachments.length - 1;

                      if (isLastItem) {
                        scrollViewPadding.value = itemWidth.value;
                      }

                      setAttachments((prev) =>
                        prev.filter((attachment) => attachment.id !== item.id)
                      );
                    }}
                  />
                  <Image
                    source={{ uri: item.uri }}
                    style={[
                      styles.imageStyle,
                      { borderColor: theme.colors.border },
                    ]}
                    contentFit="cover"
                  />
                </Animated.View>
              )}
              ListFooterComponent={() => (
                <Animated.View style={animatedPadding} />
              )}
              contentContainerStyle={styles.contentContainer}
            />
          )}
          <Animated.View layout={LinearTransition.springify()}>
            <TextInput
              multiline
              placeholder="Type a message"
              placeholderTextColor={theme.colors.border}
              cursorColor={theme.colors.primary}
              selectionHandleColor={theme.colors.primary}
              selectionColor={Color(theme.colors.primary).alpha(0.3).toString()}
              style={[
                styles.input,
                { color: theme.colors.text, outline: "none" },
              ]}
            />
          </Animated.View>
        </Animated.View>
        <Animated.View
          layout={LinearTransition.springify()}
          style={[
            styles.sendButtonContainer,
            {
              backgroundColor: theme.colors.card,
              borderWidth: StyleSheet.hairlineWidth,
              borderColor: theme.colors.border,
              boxShadow: `0px 5px 5px ${Color(theme.colors.border)
                .alpha(0.5)
                .toString()}`,
            },
          ]}
        >
          <Pressable style={styles.sendButton} hitSlop={20}>
            <Feather name="arrow-right" size={20} color={theme.colors.text} />
          </Pressable>
        </Animated.View>
      </Animated.View>
    </LayoutAnimationConfig>
  );
};

const DeleteButton = ({ onPress }: { onPress: () => void }) => {
  const theme = useTheme();
  return (
    <AnimatedPressable
      entering={ZoomIn}
      exiting={ZoomOut}
      onPress={onPress}
      style={[
        styles.deleteButton,
        {
          backgroundColor: Color(theme.colors.text).darken(0.2).toString(),
        },
      ]}
    >
      <Ionicons name="close" size={14} color={theme.colors.card} />
    </AnimatedPressable>
  );
};

const fadeZoomIn = () => {
  "worklet";
  const animations = {
    opacity: withTiming(1),
    transform: [{ scale: withSpring(1) }],
  };
  const initialValues = {
    opacity: 0,
    transform: [{ scale: 0.8 }],
  };
  return {
    initialValues,
    animations,
  };
};

const fadeZoomOut = () => {
  "worklet";
  const animations = {
    opacity: withTiming(0),
    transform: [{ scale: withSpring(0.8) }],
  };
  const initialValues = {
    opacity: 1,
    transform: [{ scale: 1 }],
  };
  return {
    initialValues,
    animations,
  };
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    width: "100%",
    maxWidth: 400,
    minWidth: 200,
    marginHorizontal: "auto",
    marginBottom: 50,
  },
  content: {
    flex: 1,
  },
  inputToolbar: {
    flexDirection: "row",
    margin: 10,
    gap: 10,
    alignItems: "flex-end",
  },
  input: {
    paddingHorizontal: 15,
    paddingVertical: 10,
    fontSize: 16,
    height: 40,
    maxHeight: 200,
  },
  inputContainer: {
    flex: 1,
    borderRadius: 20,
  },
  sendButtonContainer: {
    borderRadius: 100,
    height: 40,
    width: 40,
  },
  sendButton: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
  },
  deleteButton: {
    backgroundColor: "rgba(111,111,111,1)",
    width: 16,
    height: 16,
    justifyContent: "center",
    alignItems: "center",
    borderRadius: 100,
    position: "absolute",
    top: -5,
    right: -5,
    zIndex: 10,
  },
  imageStyle: {
    width: 100,
    height: 100,
    borderRadius: 10,
    borderWidth: 1,
  },
  contentContainer: {
    flexDirection: "row",
  },
});
