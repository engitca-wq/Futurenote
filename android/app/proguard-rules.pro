# Keep ML Kit and Play Services classes that are loaded by reflection.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.** { *; }
-keep class com.google_mlkit_digital_ink_recognition.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**
