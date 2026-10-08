# The sing-box core calls into these classes from Go through JNI, by name.
# Shrinking or renaming them breaks the library at runtime.
-keep class io.nekohasekai.libbox.** { *; }
-keep class go.** { *; }
