# kotlinx.serialization: the core's JSON models keep their serializers.
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keepclassmembers class kotlinx.serialization.json.** { *** Companion; }
-keepclasseswithmembers class kotlinx.serialization.json.** { kotlinx.serialization.KSerializer serializer(...); }
-keep,includedescriptorclasses class com.danyzmaj.pocketterm.**$$serializer { *; }
-keepclassmembers class com.danyzmaj.pocketterm.** { *** Companion; }
-keepclasseswithmembers class com.danyzmaj.pocketterm.** { kotlinx.serialization.KSerializer serializer(...); }
# OkHttp's optional TLS providers aren't on Android.
-dontwarn org.bouncycastle.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
