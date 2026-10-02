# TensorFlow Lite: the optional GPU delegate is not bundled.
-dontwarn org.tensorflow.lite.gpu.**
-keep class org.tensorflow.lite.** { *; }
# ML Kit on-device models.
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**
