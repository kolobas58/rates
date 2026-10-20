#!/usr/bin/env bash
# Готовит платформенную часть проекта (её нет в репозитории — генерирует сам Flutter) и подставляет
# название окна, размер, разрешение на интернет и значок. Запуск: bash tool/prepare.sh android|linux|windows
set -euo pipefail
P="$1"
flutter create --org club.kolobas58 --project-name rates --platforms="$P" .
case "$P" in
  android)
    M=android/app/src/main/AndroidManifest.xml
    sed -i 's/android:label="rates"/android:label="Курс валют"/' "$M"
    grep -q 'android.permission.INTERNET' "$M" || sed -i '0,/<application/s//<uses-permission android:name="android.permission.INTERNET"\/>\n    <application/' "$M"
    # автообновление (ota_update): разрешение ставить APK и FileProvider для скачанного файла
    grep -q 'REQUEST_INSTALL_PACKAGES' "$M" || sed -i '0,/<application/s//<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"\/>\n    <application/' "$M"
    grep -q 'ota_update_provider' "$M" || sed -i 's#</application>#    <provider android:name="sk.fourq.otaupdate.OtaUpdateFileProvider" android:authorities="${applicationId}.ota_update_provider" android:exported="false" android:grantUriPermissions="true">\n            <meta-data android:name="android.support.FILE_PROVIDER_PATHS" android:resource="@xml/filepaths"/>\n        </provider>\n    </application>#' "$M"
    # старые плагины (ota_update) собираются с compileSdk 28 → ошибка «android:attr/lStar not found»; поднимаем всем библиотекам
    G=android/build.gradle
    if [ -f "$G" ] && ! grep -q 'compileSdkVersion 34 // libs' "$G"; then
      printf 'subprojects {\n    afterEvaluate { p ->\n        if (p.plugins.hasPlugin("com.android.library")) { p.android { compileSdkVersion 34 // libs\n } }\n    }\n}\n' | cat - "$G" > "$G.tmp" && mv "$G.tmp" "$G"
    fi
    mkdir -p android/app/src/main/res/xml
    cat > android/app/src/main/res/xml/filepaths.xml <<'X'
<?xml version="1.0" encoding="utf-8"?>
<paths>
    <external-path name="external" path="."/>
    <external-files-path name="external_files" path="."/>
    <files-path name="files" path="."/>
    <cache-path name="cache" path="."/>
</paths>
X
    ;;
  linux)
    F=linux/runner/my_application.cc
    [ -f "$F" ] || F=linux/my_application.cc
    sed -i 's/"rates")/"Курс валют")/g; s/gtk_window_set_default_size(window, 1280, 720)/gtk_window_set_default_size(window, 520, 860)/' "$F"
    ;;
  windows)
    F=windows/runner/main.cpp
    sed -i 's/L"rates"/L"\\u041a\\u0443\\u0440\\u0441 \\u0432\\u0430\\u043b\\u044e\\u0442"/; s/Win32Window::Size size(1280, 720)/Win32Window::Size size(520, 860)/' "$F"
    R=windows/runner/Runner.rc
    sed -i 's/"FileDescription", "rates"/"FileDescription", "Kurs valyut by kolobas58"/; s/"ProductName", "rates"/"ProductName", "Kurs valyut"/; s/"CompanyName", "club.kolobas58"/"CompanyName", "kolobas58.club"/' "$R"
    ;;
esac
flutter pub get
# значок — только для своей платформы (иначе генератор лезет в папки, которых в этой сборке нет)
if [ "$P" = android ]; then
  cat > .icons.yaml <<'Y'
flutter_launcher_icons:
  image_path: "assets/icon.png"
  android: true
  ios: false
  min_sdk_android: 21
  adaptive_icon_background: "#128C7E"
  adaptive_icon_foreground: "assets/icon_fg.png"
Y
  dart run flutter_launcher_icons -f .icons.yaml
elif [ "$P" = windows ]; then
  cat > .icons.yaml <<'Y'
flutter_launcher_icons:
  android: false
  ios: false
  windows:
    generate: true
    image_path: "assets/icon.png"
    icon_size: 256
Y
  dart run flutter_launcher_icons -f .icons.yaml
fi
echo "prepared $P"
